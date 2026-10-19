-- 500 concurrent logins: 5,000 seeded users (under the 10-per-email limit), a random client address each
-- (trusted via TRUSTED_PROXIES) so the rate limiter is not what we measure.
local counter = 0
local statuses = {}
local threads = {}

function setup(thread)
  thread:set("id", counter)
  table.insert(threads, thread)
  counter = counter + 1
end

function init(args)
  math.randomseed(1000 + id)
  codes = {}
end

request = function()
  local n = math.random(0, 4999)
  local ip = string.format("10.%d.%d.%d", math.random(0, 255), math.random(0, 255), math.random(1, 254))
  local body = string.format('{"email":"load%d@load.say","password":"load-test-password"}', n)
  return wrk.format("POST", "/v1/auth/login",
    { ["Content-Type"] = "application/json", ["X-Forwarded-For"] = ip }, body)
end

response = function(status, headers, body)
  codes[status] = (codes[status] or 0) + 1
end

done = function(summary, latency, requests)
  local total = {}
  for _, t in ipairs(threads) do
    local c = t:get("codes")
    for k, v in pairs(c) do total[k] = (total[k] or 0) + v end
  end
  io.write("login statuses:")
  for k, v in pairs(total) do io.write(string.format(" %s=%d", k, v)) end
  io.write("\n")
  io.write(string.format("login latency ms: p50=%.1f p95=%.1f p99=%.1f max=%.1f\n",
    latency:percentile(50) / 1000, latency:percentile(95) / 1000,
    latency:percentile(99) / 1000, latency.max / 1000))
end
