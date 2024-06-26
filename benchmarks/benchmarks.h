#pragma once

#include "types.h"
#include <cstdint>
#include <functional>
#include <optional>

// Table type
enum class TableType {
	CUCKOO,
	ICEBERG,
};

// Table specification
struct TableSpec {
	TableType type;
	uint8_t p_row_width, p_bucket_size;
	uint8_t s_row_width, s_bucket_size;
	auto operator<=>(const TableSpec&) const = default;
};

// Run-time table configuration
struct TableConfig {
	uint8_t key_width;
	uint8_t p_addr_width;
	uint8_t s_addr_width;
	std::optional<Rng> rng = std::nullopt;
};

bool spec_fits_config(const TableSpec spec, const TableConfig config);

// Find benchmark
// TODO: we may want to have multiple percentages of hits and misses
struct FindBenchmark {
	const key_type *put_keys, *put_keys_end;
	const key_type *queries, *queries_end;
};
struct FindResult {
	std::optional<float> average_ms;
};

// Find-or-put benchmark
struct FopBenchmark {
	key_type *keys, *keys_end;
};
struct FopResult {
	std::optional<float> average_ms;
};

// Single-run find-or-put benchmark
using OneFopBenchmark = FindBenchmark;
using OneFopResult = FopResult;

// Put benchmark
//
// Same parameters as for find-or-put
using PutBenchmark = FopBenchmark;
using PutResult = FopResult;

// Runners
using FindRunner = std::function<FindResult(TableConfig, FindBenchmark)>;
using FopRunner = std::function<FopResult(TableConfig, FopBenchmark)>;
using PutRunner = std::function<PutResult(TableConfig, PutBenchmark)>;
using OneFopRunner = std::function<OneFopResult(TableConfig, OneFopBenchmark)>;
struct Runners { FindRunner find; FopRunner fop; OneFopRunner one_fop; PutRunner put; };

// Get runners for given table specification
//
// This only works for "registered" specifications.
// Specifications are registered in benchmarks.cu
// 
// Throws std::out_of_range if spec is not registered.
Runners get_runners(TableSpec spec);

// Query if table with given spec is registered
bool has_runners(TableSpec spec);
