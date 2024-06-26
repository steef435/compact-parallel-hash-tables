#include "cuckoo.cuh"
#include "iceberg.cuh"
#include "benchmarks.h"
#include "timer.h"
#include <thrust/find.h>
#include <thrust/iterator/constant_iterator.h>
#include <map>
#include <numeric>
#include <type_traits>

bool spec_fits_config(const TableSpec spec, const TableConfig config) {
	const auto p_rem_w = config.key_width - config.p_addr_width;
	const auto s_rem_w = config.key_width - config.s_addr_width;

	if (spec.type == TableType::CUCKOO) {
		return spec.p_row_width >= 2 + p_rem_w;
	} else {
		return (spec.p_row_width >= 1 + p_rem_w)
			&& (spec.s_row_width >= 2 + s_rem_w);
	}
}

// Runs per benchmark. First run is discarded.
constexpr auto N_RUNS = 3;
// Steps in fop-benchmark
constexpr auto N_STEPS = 10;

// For ignoring find results without incurring bandwidth
// This is basically the implementation of std::ignore (not guaranteed by spec)
// We currently do not use this, as BGHT does not either
struct Ignorer {
	template <typename T>
	constexpr void operator=(T&&) const noexcept {}
};

// Only keeps track of whether failure occured, thus saving bandwidth
__device__ struct FailFlag {
	bool failed = false;

	__device__ void operator=(const Result& result) noexcept {
		if (!failed && result == Result::FULL) {
			failed = true;
		}
	}
} FAILFLAG;

// This can be used as a dummy Result iterator for storing results
// It only keeps track of whether any thread failed using FailFlag
// It does not have much of a runtime impact, but does save space
//
// Do note the use of the global device variable FAILFLAG. This would be unsafe
// to use in multithreaded / mutli-stream scenarios! But we do not use this.
// TODO: modify API so that there is only a read-and-reset function to avoid
// pitfalls where one might use an unresetted ignorer.
struct SuccessIgnorer {
	__device__ FailFlag& operator[](size_t) {
		return FAILFLAG;
	}

	bool failed() {
		bool tmp;
		CUDA(cudaMemcpyFromSymbol(&tmp, FAILFLAG.failed, sizeof(tmp)));
		return tmp;
	}

	void reset(bool to = false) {
		CUDA(cudaMemcpyToSymbol(FAILFLAG.failed, &to, sizeof(to)));
	}

	SuccessIgnorer() {
		reset();
	}
};

//
// Runners
//

// Row type for given width
//
// For convenience, we also support width == 0, which maps to void
template <uint8_t width>
requires (width == 64 || width == 32 || width == 16 || width == 0)
using row_type = std::conditional_t<width == 64, unsigned long long,
	std::conditional_t<width == 32, uint32_t,
	std::conditional_t<width == 16, uint16_t, void>>>;

template <TableSpec spec>
using p_row_t = row_type<spec.p_row_width>;

template <TableSpec spec>
using s_row_t = row_type<spec.s_row_width>;

// We use here that the current _implementation_ of std::conditional short
// circuits on the false path (here: if type is CUCKOO, then we get no Iceberg
// template errors for having a s_row_width of 0).
template <TableSpec spec>
using Table = std::conditional_t<spec.type == TableType::ICEBERG,
	Iceberg<p_row_t<spec>, spec.p_bucket_size, s_row_t<spec>, spec.s_bucket_size>,
	Cuckoo<p_row_t<spec>, spec.p_bucket_size>>;

template <TableSpec spec>
static Table<spec> make_table(TableConfig conf) {
	using Table = Table<spec>;
	if constexpr (spec.type == TableType::CUCKOO) {
		return Table(conf.key_width, conf.p_addr_width, conf.rng);
	} else {
		return Table(conf.key_width, conf.p_addr_width,
			conf.s_addr_width, conf.rng);
	}
}

// Fill table with keys, return true iff successful
template <typename Table>
static bool prefill(Table &table, const key_type *start, const key_type *end) {
	const auto len = end - start;
	if (len == 0) return true;
	SuccessIgnorer ignore_results;
	table.put(start, end, ignore_results);
	bool success = !ignore_results.failed();
	ignore_results.reset();
	return success;
}

template <TableSpec spec>
FindResult find_runner(TableConfig conf, FindBenchmark bench) {
	auto table = make_table<spec>(conf);

	if (!prefill(table, bench.put_keys, bench.put_keys_end)) return { {} };

	const auto len = bench.queries_end - bench.queries;
	auto _results = cusp(alloc_dev<bool>(len));
	auto results = _results.get();
	// Save bandwidth using result = thrust::constant_iterator<Ignorer> result_ignorer;

	Timer timer;
	for (auto i = 0; i < N_RUNS; i++) {
		if (i == 1) timer.start(); // ignore first measurement
		table.find(bench.queries, bench.queries_end, results, false);
	}
	auto elapsed = timer.stop();

	return { elapsed /  (N_RUNS - 1) };
}

// This is currently unused and has probably acquired bit rot.
// The rates benchmark uses one_fop_runner
template <TableSpec spec>
FopResult fop_runner(TableConfig conf, FopBenchmark bench) {
	const auto len = bench.keys_end - bench.keys;
	assert(len % N_STEPS == 0);
	float times_ms[N_RUNS];

	auto table = make_table<spec>(conf);
	Result *results;
	CUDA(cudaMallocManaged(&results, sizeof(*results) * len));
	key_type *tmp;
	CUDA(cudaMallocManaged(&tmp, sizeof(*tmp) * len * 2));

	Timer timer;
	for (auto i = 0; i < N_RUNS; i++) {
		table.clear();

		timer.start();
		for (auto n = 0; n < len; n += len / N_STEPS) {
			if constexpr (spec.type == TableType::CUCKOO) {
				table.find_or_put(bench.keys, bench.keys + n, tmp, results, false);
			} else {
				table.find_or_put(bench.keys, bench.keys + n, results, false);
			}
		}
		times_ms[i] = timer.stop();

		CUDA(cudaDeviceSynchronize());
		bool full = thrust::find(thrust::device,
			results, results + len, Result::FULL) != results + len;
		if (full) return FopResult { {} };
	}

	CUDA(cudaFree(results));
	CUDA(cudaFree(tmp));

	return FopResult {
		std::accumulate(times_ms + 1, times_ms + N_RUNS, 0.f) / (N_RUNS - 1)
	};
}

template <TableSpec spec>
OneFopResult one_fop_runner(TableConfig conf, OneFopBenchmark bench) {
	auto table = make_table<spec>(conf);

	const auto len = bench.queries_end - bench.queries;
	float times_ms[N_RUNS];

	// Cuckoo needs temporary storage and real result storage
	// (We cannot use SuccessIgnorer for Cuckoo, as the result array is
	// used for temporary storage in Cuckoo find-or-put). This is slightly
	// unfair for cuckoo, but on the other hand, the allocation time of
	// temporaries is not measured so Cuckoo gets a larger advantage there
	CuSP<key_type> _tmp;
	key_type *tmp;
	CuSP<Result> _cuckoo_results;
	Result *cuckoo_results;
	SuccessIgnorer iceberg_ignore_results;
	if constexpr (spec.type == TableType::CUCKOO) {
		_tmp = cusp(alloc_dev<key_type>(len * 2));
		tmp = _tmp.get();

		_cuckoo_results = cusp(alloc_dev<Result>(len));
		cuckoo_results = _cuckoo_results.get();
	}

	Timer timer;
	for (auto i = 0; i < N_RUNS; i++) {
		table.clear();
		if (!prefill(table, bench.put_keys, bench.put_keys_end)) {
			return { {} };
		}
		iceberg_ignore_results.reset();

		timer.start();
		if constexpr (spec.type == TableType::CUCKOO) {
			table.find_or_put(bench.queries, bench.queries_end,
					tmp, cuckoo_results, false);
		} else {
			table.find_or_put(bench.queries, bench.queries_end,
					iceberg_ignore_results, false);
		}
		times_ms[i] = timer.stop();

		CUDA(cudaDeviceSynchronize());
		bool full = iceberg_ignore_results.failed();
		if constexpr (spec.type == TableType::CUCKOO) {
			full = thrust::find(thrust::device,
					cuckoo_results, cuckoo_results + len,
					Result::FULL) != cuckoo_results + len;
		}
		if (full) return OneFopResult { {} };
	}

	return OneFopResult {
		std::accumulate(times_ms + 1, times_ms + N_RUNS, 0.f) / (N_RUNS - 1)
	};
}

template <TableSpec spec>
PutResult put_runner(TableConfig conf, PutBenchmark bench) {
	float times_ms[N_RUNS];

	auto table = make_table<spec>(conf);

	SuccessIgnorer results;
	// If you want to store all return values instead:
	//const auto len = bench.keys_end - bench.keys;
	//auto _results = cusp(alloc_dev<Result>(len));
	//auto *results = _results.get();

	Timer timer;
	for (auto i = 0; i < N_RUNS; i++) {
		table.clear();
		results.reset();

		timer.start();
		table.put(bench.keys, bench.keys_end, results, false);
		times_ms[i] = timer.stop();

		CUDA(cudaDeviceSynchronize());
		// When storing all return values:
		//bool full = thrust::find(thrust::device,
		//	results, results + len, Result::FULL) != results + len;
		//if (full) return PutResult { {} };
		if (results.failed()) return PutResult { {} };
	}

	return PutResult {
		std::accumulate(times_ms + 1, times_ms + N_RUNS, 0.f) / (N_RUNS - 1)
	};
}

//
// Runners registry
//

template <TableSpec spec>
static Runners make_runners() {
	return Runners {
		find_runner<spec>,
		fop_runner<spec>,
		one_fop_runner<spec>,
		put_runner<spec>,
	};
}

template <TableType type, uint8_t prw, uint8_t pbs, uint8_t srw, uint8_t sbs>
static std::pair<TableSpec, Runners> registration() {
	constexpr TableSpec spec { type, prw, pbs, srw, sbs };
	return { spec, make_runners<spec>() };
}

template <uint8_t prw, uint8_t pbs>
static auto cuckoo = registration<TableType::CUCKOO, prw, pbs, 0, 0>();

template <uint8_t prw, uint8_t pbs, uint8_t srw, uint8_t sbs>
static auto iceberg = registration<TableType::ICEBERG, prw, pbs, srw, sbs>();

static const std::map<TableSpec, Runners> registry {
	cuckoo<32, 32>,
	cuckoo<32, 16>,
	cuckoo<32,  8>,
	cuckoo<32,  4>,
	cuckoo<32,  2>,
	cuckoo<32,  1>,

	cuckoo<64, 32>,
	cuckoo<64, 16>,
	cuckoo<64,  8>,
	cuckoo<64,  4>,
	cuckoo<64,  2>,
	cuckoo<64,  1>,

	iceberg<16, 32, 16, 16>,
	iceberg<16, 16, 16,  8>,
	iceberg<16,  8, 16,  4>,
	iceberg<16,  4, 16,  2>,
	iceberg<16,  2, 16,  1>,

	iceberg<16, 32, 32, 16>,
	iceberg<16, 16, 32,  8>,
	iceberg<16,  8, 32,  4>,
	iceberg<16,  4, 32,  2>,
	iceberg<16,  2, 32,  1>,

	iceberg<32, 32, 32, 16>,
	iceberg<32, 16, 32,  8>,
	iceberg<32, 16, 32,  4>,
	iceberg<32, 16, 32,  2>,
	iceberg<32,  8, 32,  4>,
	iceberg<32,  8, 32,  2>,
	iceberg<32,  4, 32,  2>,
	iceberg<32,  2, 32,  1>,

	iceberg<64, 32, 64, 16>,
	iceberg<64, 16, 64,  8>,
	iceberg<64,  8, 64,  4>,
	iceberg<64,  4, 64,  2>,
	iceberg<64,  2, 64,  1>,
};

Runners get_runners(TableSpec spec) {
	return registry.at(spec);
}

bool has_runners(TableSpec spec) {
	return registry.contains(spec);
}
