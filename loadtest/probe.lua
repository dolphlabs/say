-- The unrelated endpoint, measured while logins flood the hashing pool.
done = function(summary, latency, requests)
  io.write(string.format("probe %s: requests=%d errors=%d p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms\n",
    os.getenv("PROBE_LABEL") or "",
    summary.requests, summary.errors.status + summary.errors.connect + summary.errors.timeout,
    latency:percentile(50) / 1000, latency:percentile(95) / 1000,
    latency:percentile(99) / 1000, latency.max / 1000))
end
