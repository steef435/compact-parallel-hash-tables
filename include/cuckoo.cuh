#pragma once

#include <cooperative_groups.h>
#include <thrust/execution_policy.h>
#include <thrust/fill.h>
#include <thrust/iterator/permutation_iterator.h>
#include <thrust/sequence.h>
#include <thrust/sort.h>
#include <bit>
#include <limits>
#include <functional>
#include <utility>
#include "bits.h"
#include "cuda_util.cuh"
#include "quotient.cuh"
#include "table.cuh"

namespace cg = cooperative_groups;

// A Cuckoo hash table 
template <
	typename row_type,
	uint8_t bucket_size,
	class Permute = RngPermute,
	uint8_t n_hash_functions = 3,
	bool unified_memory = false
>
class Cuckoo {
	static_assert(bucket_size > 0, "bucket size must be nonzero");
	static_assert(32 % bucket_size == 0, "warp/bucket size must divide 32");

public:
	// TODO: make this configurable? In BCHT this depends on n_rows
	static const auto max_chain_length = 20 * n_hash_functions;
	static constexpr int block_size = 128;
	static_assert(block_size % bucket_size == 0);

	const Permute permute;

	const uint8_t row_width = sizeof(row_type) * 8;
	const uint8_t addr_width, rem_width; // in bits
	const size_t n_rows;
	// state ::= empty | occupied hash_id
	const uint8_t state_width = std::bit_width(n_hash_functions);

	using Tile = cg::thread_block_tile<bucket_size, cg::thread_block>;
	using AddrRow = std::pair<addr_type, row_type>;
	using HashKey = std::pair<uint8_t, key_type>;

	// The storage backend
	// Row entries are stored as follows:
	// - the most significant state_width bits indicate the state
	//   - state 0 is for empty rows
	//   - state 1 + i indicates hash function i
	// - the least significant rem_width bits indicate the remainder
	row_type *rows;
	CuSP<row_type> _rows; // shared pointer for handling the memory

	// Hash key to an address and a row entry
	__host__ __device__ AddrRow addr_row(const uint8_t hash_id, const key_type k) {
		const auto pk = permute(hash_id, k);
		const addr_type addr = pk & mask<key_type>(addr_width);
		const auto rem = pk >> addr_width;
		return { addr, (row_type(hash_id + 1) << (row_width - state_width)) | rem };
	}

	// Restore hash id and key from address and row
	__host__ __device__ HashKey hash_key(const addr_type addr, const row_type row) {
		assert(row != 0);
		const auto hash_id = (row >> (row_width - state_width)) - 1;
		assert(hash_id < n_hash_functions);
		const auto rem = row & mask<row_type>(rem_width);
		const auto pk = (rem << addr_width) | addr;
		return { hash_id, permute.inv(hash_id, pk) };
	}

	// Count the number of occurrences of key k in the table
	//
	// The host function works only when using unified memory
	__host__ __device__ unsigned count(const key_type k) {
#ifndef  __CUDA_ARCH__
		assert(unified_memory);
#endif
		unsigned count = 0;
		for (auto hid = 0; hid < n_hash_functions; hid++) {
			const auto [addr, row] = addr_row(hid, k);
			for (auto bi = 0; bi < bucket_size; bi++) {
				if (rows[addr * bucket_size + bi] == row) count++;
			}
		}
		return count;
	}

	// Divide work between tiled threads
	//
	// F(key, tile) is called for every key from start to end (exclusive) by one Tile
	// the associated return value is stored in results
	template <auto F, class KeyIt, class ResIt>
	__device__ void coop(const KeyIt start, const KeyIt end, ResIt results) {
		const auto index = blockIdx.x * blockDim.x + threadIdx.x;
		const auto stride = gridDim.x * blockDim.x;
		const auto len = end - start;
		const auto max = ((len + bucket_size - 1) / bucket_size) * bucket_size;

		for (auto i = index; i < max; i += stride) {
			key_type k;
			bool to_act = i < len;
			if (to_act) k = start[i];

			const auto thb = cg::this_thread_block();
			const auto tile = cg::tiled_partition<bucket_size>(thb);
			const auto rank = tile.thread_rank();
			while (auto queue = tile.ballot(to_act)) {
				const auto leader = __ffs(queue) - 1;
				const auto res = std::invoke(F, this,
						tile.shfl(k, leader), tile);
				if (rank == leader) {
					results[i] = res;
					to_act = false;
				}
			}
		}
	}

	// Divide work between tiled threads. Only act on the first of every similar block
	//
	// F(key, tile) is called for every first unique key start[i] from
	// start to end (exclusive) by one Tile. The associated return value is
	// stored in results[i].
	//
	// Assumes keys are sorted.
	template <auto F, class KeyIt, class ResIt>
	__device__ void coop_sorted(const KeyIt start, const KeyIt end, ResIt results) {
		const auto index = blockIdx.x * blockDim.x + threadIdx.x;
		const auto stride = gridDim.x * blockDim.x;
		const auto len = end - start;
		const auto max = ((len + bucket_size - 1) / bucket_size) * bucket_size;

		for (auto i = index; i < max; i += stride) {
			key_type k;
			const bool in_range = i < len;
			if (in_range) k = start[i];
			const bool first = in_range && (index == 0 || k != start[i - 1]);
			bool to_act = in_range && first;

			const auto thb = cg::this_thread_block();
			const auto tile = cg::tiled_partition<bucket_size>(thb);
			const auto rank = tile.thread_rank();
			while (auto queue = tile.ballot(to_act)) {
				const auto leader = __ffs(queue) - 1;
				const auto res = std::invoke(F, this,
						tile.shfl(k, leader), tile);
				if (rank == leader) {
					results[i] = res;
					to_act = false;
				}
			}
		}
	}

	// Cooperatively find k
	//
	// Returns true if and only if k is found in the table.
	// The search is stopped as soon as a non-full bucket without k is encountered.
	// (So it works with the assumption that filled rows are never cleared.)
	//
	// NOTE: If used concurrently with put, false negatives may occur
	__device__ bool coop_find(const key_type k, const Tile tile) {
		const auto rank = tile.thread_rank();
		for (auto hid = 0; hid < n_hash_functions; hid++) {
			const auto [addr, row] = addr_row(hid, k);
			const auto curr = rows[addr * bucket_size + rank];
			if (tile.any(curr == row)) return true;
			if (tile.any(curr == 0)) return false;
		}
		return false;
	}

	// Look up given keys in the table
	//
	// Afterwards, results[i] is true iff start[i] is in the table
	//
	// Assumes a 1d thread layout, and that p_bucket_size divides blockDim.x
	__device__ void _find(const key_type *start, const key_type *end, bool *results) {
		coop<&Cuckoo::coop_find>(start, end, results);
	}

	// Attempt to find given keys in the table
	template <class KeyIt, class BoolIt>
	void find(const KeyIt start, const KeyIt end, BoolIt results, bool sync = true) {
		const int n_blocks = ((end - start) + block_size - 1) / block_size;
		invoke_device<&Cuckoo::coop<&Cuckoo::coop_find, KeyIt, BoolIt>>
			<<<n_blocks, block_size>>>(*this, start, end, results);

		if (sync) CUDA(cudaDeviceSynchronize());
	}

	// NOTE: does not handle duplicates!
	// If avoid_dups is true, tries to avoid some in-bucket duplicates
	template <bool avoid_dups = false>
	__device__ Result coop_put(key_type k, const Tile tile) {
		using enum Result;
		const auto rank = tile.thread_rank();

		auto chain_length = 0, hashid = 0;
		while (true) {
			const auto [addr, row] = addr_row(hashid, k);
			row_type *my_addr = rows + addr * bucket_size + rank;
			row_type tmp = *my_addr;
			if constexpr (avoid_dups) {
				if (tile.any(tmp == row)) return FOUND;
			}

			const auto load = __popc(tile.ballot(tmp != 0));
			if (load < bucket_size) { // insert in empty row
				if (rank == load) {
					tmp = atomicCAS(my_addr, 0, row);
				}
				tmp = tile.shfl(tmp, load);
				if (tmp == 0) return PUT;
				if constexpr (avoid_dups) {
					if (tmp == row) return FOUND;
				}
			} else { // we have to Cuckoo
				if (chain_length >= max_chain_length) return FULL;
				// TODO: we have multiple objectives here:
				// - we want to Cuckoo a random row from the bucket
				//   (to avoid atomic operation congestion on certain rows)
				// - but it needs to be fast
				// - it does not need not be cryptographically secure
				// - in BCHT, they appear to use an RNG based on the so-called KISS generator,
				//   but all threads seem to start from the same seed in every call to insert().
				//   (Knowing that most chains have a small length, this means that the threads
				//   essentially all work on the same handful of row offsets: not great)
				// - I hypothesize the below is good enough
				const auto cuckoor =
					(blockIdx.x * blockDim.x + tile.meta_group_rank() + chain_length) % bucket_size;
				if (rank == cuckoor) {
					tmp = atomicExch(my_addr, row);
				}
				tmp = tile.shfl(tmp, cuckoor);
				if constexpr (avoid_dups) {
					if (tmp == row) return FOUND;
				}
				std::tie(hashid, k) = hash_key(addr, tmp);
				hashid = (hashid + 1) % n_hash_functions;
				chain_length++;
			}
		}
	}

	// Attempt to put given keys in the table
	//
	// Assumes a 1d thread layout, and that p_bucket_size divides blockDim.x
	__device__ void _put(const key_type *start, const key_type *end, Result *results) {
		coop<&Cuckoo::coop_put<false>>(start, end, results);
	}

	// Attempt to put given keys in the table
	template <class KeyIt, class ResIt>
	void put(const KeyIt start, const KeyIt end, ResIt results, bool sync = true) {
		const int n_blocks = ((end - start) + block_size - 1) / block_size;
		// calls _put
		invoke_device<&Cuckoo::coop<&Cuckoo::coop_put<false>, KeyIt, ResIt>>
			<<<n_blocks, block_size>>>(*this, start, end, results);
		if (sync) CUDA(cudaDeviceSynchronize());
	}

	// Attempt to put given keys in the table, partly avoiding in-bucket duplicates
	//
	// Does _not_ guarantee no duplicates
	template <class KeyIt, class ResIt>
	void put_avoid_dups(const KeyIt start, const KeyIt end, ResIt results, bool sync = true) {
		const int n_blocks = ((end - start) + block_size - 1) / block_size;
		invoke_device<&Cuckoo::coop<&Cuckoo::coop_put<true>, KeyIt, ResIt>>
			<<<n_blocks, block_size>>>(*this, start, end, results);
		if (sync) CUDA(cudaDeviceSynchronize());
	}

	// Translate coop_find to Result, so that true is FOUND and false is PUT
	//
	// (Used in find_or_put for saving memory)
	__device__ Result coop_find_as_result(const key_type k, const Tile t) {
		using enum Result;
		return coop_find(k, t) ? FOUND : PUT;
	}

	// If results[i] != FOUND, put start[i] into the table
	//
	// Only the first copy of every such key is inserted. All other keys
	// have their result set as FOUND, _even if their insertion failed!_
	// (For performance reasons.) TODO: is this fair?
	template <class KeyIt, class ResIt>
	__device__ void put_if_not_found_sorted(const KeyIt start, const KeyIt end, ResIt results) {
		const auto index = blockIdx.x * blockDim.x + threadIdx.x;
		const auto stride = gridDim.x * blockDim.x;
		const auto len = end - start;
		const auto max = ((len + bucket_size - 1) / bucket_size) * bucket_size;

		for (auto i = index; i < max; i += stride) {
			key_type k;
			const bool in_range = i < len;
			if (in_range) k = start[i];
			const bool first = in_range && (index == 0 || k != start[i - 1]);

			bool to_act = in_range && first && results[i] != Result::FOUND;
			const auto thb = cg::this_thread_block();
			const auto tile = cg::tiled_partition<bucket_size>(thb);
			const auto rank = tile.thread_rank();
			while (auto queue = tile.ballot(to_act)) {
				const auto leader = __ffs(queue) - 1;
				const auto res = coop_put(tile.shfl(k, leader), tile);
				if (rank == leader) {
					results[i] = res;
					to_act = false;
				}
			}

			if (in_range && !first) results[i] = Result::FOUND;
		}
	}

	// Find-or-put keys, assuming keys is sorted
	//
	// For every first key of its kind, the result is:
	// - FOUND if it was already in the table
	// - PUT if it was not already in the table, and has been put in
	// - FULL if it was not already in the table, and could not be put in
	// The results of all other keys is always FOUND (even if it was not inserted!)
	template <class KeyIt, class ResIt>
	void find_or_put_sorted(const KeyIt keys, const KeyIt end, ResIt results, bool sync = true) {
		const auto len = end - keys;
		const int n_blocks = (len + block_size - 1) / block_size;

		invoke_device<&Cuckoo::coop_sorted<&Cuckoo::coop_find_as_result, KeyIt, ResIt>>
			<<<n_blocks, block_size>>>(*this, keys, keys + len, results);

		invoke_device<&Cuckoo::put_if_not_found_sorted<KeyIt, ResIt>>
			<<<n_blocks, block_size>>>(*this, keys, keys + len, results);

		if (sync) CUDA(cudaDeviceSynchronize());
	}

	// A safe find-or-put for Cuckoo
	//
	// tmp should point to a device buffer twice the size of supplied keys*
	//
	// For every first key of its kind, the result is:
	// - FOUND if it was already in the table
	// - PUT if it was not already in the table, and has been put in
	// - FULL if it was not already in the table, and could not be put in
	// The results of all other keys is always FOUND (even if it was not inserted!)
	//
	// * The length of the keys array should also be expressible in key_type
	//   (this assumption could be removed, see implementation)
	//
	// Perhaps this could be made more efficient, especially in terms of
	// memory usage. By taking tmp as an argument, the cost of allocating
	// it is not measured in benchmarks at least.
	void find_or_put(const key_type *keys, const key_type *end, key_type *tmp, Result *results, bool sync = true) {
		const auto klen = end - keys;
		// The first constraint can be alleviated by changing buffer requirements (tmp)
		// The second constraint is due to Thrust (https://github.com/NVIDIA/cccl/issues/744)
		assert(klen <= std::numeric_limits<key_type>::max());
		assert(klen <= std::numeric_limits<int>::max());

		auto indices = tmp;
		auto kcopies = tmp + klen;

		// Sort the keys, remembering their index
		// (so that kcopies[i] < kcopies[i+1] and keys[indices[j]] = kcopies[j])
		// TODO: It would be nicer if we could just sort the indices.
		// However, I fear that thrust sorting with a custom comparator
		// will be significantly slower than this, because of memory
		// locality and because thrust appears to use radix sort for
		// builtins and mergesort for custom comparators.
		thrust::copy(thrust::device, keys, end, kcopies);
		thrust::sequence(thrust::device, indices, indices + klen);
		thrust::stable_sort_by_key(thrust::device, kcopies, kcopies + klen, indices);

		// Low-overhead view into sorted array
		auto key_view = thrust::permutation_iterator(keys, indices);
		auto res_view = thrust::permutation_iterator(results, indices);

		find_or_put_sorted(key_view, key_view + klen, res_view, sync);
	}

	// Clears all table rows
	void clear() {
		thrust::fill(thrust::device, rows, rows + n_rows, 0);
	}

	// Construct a Cuckoo hash table with 2^addr_width buckets for storing
	// keys key_width wide.
	//
	// key_width and addr_width to be specified in bits
	Cuckoo(const uint8_t key_width, const uint8_t addr_width,
		std::optional<Rng> rng = std::nullopt)
		: permute(key_width, rng)
		, addr_width(addr_width)
		, rem_width(key_width - addr_width)
		, n_rows((1ull << addr_width) * sizeof(*rows) * bucket_size)
	{
		// make sure row_type is wide enough
		assert(sizeof(row_type) * 8 >= state_width + rem_width);
		_rows = cusp(alloc<row_type>(n_rows, unified_memory));
		rows = _rows.get();
		clear();
	}
};

#ifdef DOCTEST_LIBRARY_INCLUDED
#include <thrust/count.h>
#include <thrust/functional.h>
#include <thrust/iterator/counting_iterator.h>
#include <thrust/logical.h>
#include <thrust/random/linear_congruential_engine.h>
#include <thrust/random/uniform_int_distribution.h>
#include <thrust/sequence.h>

TEST_CASE("Cuckoo hash table") {
	using Table = Cuckoo<uint32_t, 32, RngPermute, 3, true>;
	Table table(21, 5);
	CHECK(table.count(0) == 0);

	// Check the hashing and inverting
	// TODO: randomize?
	const Table::HashKey to_check[] { {0, 42}, {1, 365}, {2, 3'1415} };
	for (auto [hid, key] : to_check) {
		auto [a, r] = table.addr_row(hid, key);
		auto [h, k] = table.hash_key(a, r);
		CHECK(h == hid);
		CHECK(k == key);
	}

	// Some puts
	// This is not a very effective test:
	// the hashing function is so good that everything ends up in their bucket 0
	constexpr auto N = 2000;
	constexpr auto to_insert = N / 2;
	key_type *keys;
	Result *results;
	bool *found;
	CUDA(cudaMallocManaged(&keys, sizeof(*keys) * N));
	CUDA(cudaMallocManaged(&results, sizeof(*results) * N));
	CUDA(cudaMallocManaged(&found, sizeof(*found) * N));
	thrust::sequence(keys, keys + N);
	table.put(keys, keys + to_insert, results, false);
	table.find(keys, keys + N, found);
	CHECK(thrust::all_of(keys, keys + to_insert,
		[&table, results] (auto key) {
			return table.count(key) == 1 && results[key] == Result::PUT;
		}));
	CHECK(thrust::all_of(found, found + to_insert, thrust::identity<bool>()));
	CHECK(thrust::none_of(found + to_insert, found + N, thrust::identity<bool>()));

	CUDA(cudaFree(keys));
	CUDA(cudaFree(results));
	CUDA(cudaFree(found));
}

TEST_CASE("Cuckoo: sorted find-or-put") {
	using Table = Cuckoo<uint32_t, 32>;
	Table *table;
	CUDA(cudaMallocManaged(&table, sizeof(*table)));
	new (table) Table(21, 5); // 32 * 2^5 = 1024 rows


	constexpr auto N = 300;
	constexpr auto step = 30;
	static_assert(N % step == 0);

	key_type *keys;
	Result *results;
	CUDA(cudaMallocManaged(&keys, sizeof(*keys) * N));
	CUDA(cudaMallocManaged(&results, sizeof(*results) * N));
	thrust::sequence(keys, keys + N);

	for (auto n = 0; n < N; n += step) {
		table->find_or_put_sorted(keys, keys + n + step, results);
		CHECK(thrust::all_of(thrust::device, keys, keys + n,
			[table, results] __device__ (auto key) {
				return table->count(key) == 1 && results[key] == Result::FOUND;
			}));
		CHECK(thrust::all_of(thrust::device, keys + n, keys + n + step,
			[table, results] __device__ (auto key) {
				return table->count(key) == 1 && results[key] == Result::PUT;
			}));
		CHECK(thrust::all_of(thrust::device, keys + n + step, keys + N,
			[table, results] __device__ (auto key) {
				return table->count(key) == 0;
			}));
	}

	CUDA(cudaFree(keys));
	CUDA(cudaFree(results));
	CUDA(cudaFree(table));
}

TEST_CASE("Cuckoo: unordered find-or-put") {
	using Table = Cuckoo<uint32_t, 32>;
	Table *table;
	CUDA(cudaMallocManaged(&table, sizeof(*table)));
	new (table) Table(21, 5); // 32 * 2^5 = 1024 rows

	constexpr auto M = 1025;
	constexpr auto N = 800;
	constexpr auto step = 200;
	static_assert(N % step == 0);

	key_type *keys;
	Result *results;
	key_type *tmp;
	CUDA(cudaMallocManaged(&keys, sizeof(*keys) * M));
	CUDA(cudaMallocManaged(&results, sizeof(*results) * M));
	CUDA(cudaMallocManaged(&tmp, sizeof(*tmp) * M * 2));

	thrust::minstd_rand rng; // has constant seed
	thrust::uniform_int_distribution<int> dist(0, 100);
	auto gen = [&rng, &dist] () { return dist(rng); };
	thrust::generate(keys, keys + N, gen);

	for (auto n = 0; n < N; n += step) {
		table->find_or_put(keys, keys + n + step, tmp, results);
		CHECK(thrust::all_of(results, results + n,
			[] (auto res) { return res == Result::FOUND; }));
	}
	CHECK(thrust::all_of(thrust::device, keys, keys + N,
		[table] __device__ (auto k) { return table->count(k) == 1; }));

	// Now overflow the table
	thrust::sequence(keys, keys + M);
	table->find_or_put(keys, keys + M, tmp, results);
	CHECK(thrust::count(results, results + M, Result::FULL) > 0);

	CUDA(cudaFree(keys));
	CUDA(cudaFree(results));
	CUDA(cudaFree(tmp));
	CUDA(cudaFree(table));
}

TEST_CASE("Cuckoo hash table: Cuckooing behavior") {
	// TODO: make a custom permutation to properly test the Cuckooing behavior
}
#endif
