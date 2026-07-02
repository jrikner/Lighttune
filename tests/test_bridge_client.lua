-- bridge_client parse/classify tests (Phase 5 D-99)

local bridge_client = require("bridge_client")

local function read_fixture(name)
    local f = io.open("tests/fixtures/" .. name, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

return function(M)
    M.section("parse_measure_body – happy path")
    do
        local body = read_fixture("bridge_measure_ok.json")
        local data, err = bridge_client.parse_measure_body(body)
        M.assert_true("no error on ok fixture", err == nil)
        M.assert_equal("cct", data.cct, 4100)
        M.assert_equal("duv", data.duv, 0.0085)
        M.assert_equal("cri", data.cri, 72)
        M.assert_equal("r9", data.r9, 42)
        M.assert_equal("tlci", data.tlci, 68)
    end

    M.section("parse_measure_body – validation failures")
    do
        local data, err = bridge_client.parse_measure_body('{"cct":4100,"duv":0.01,"cri":72}')
        M.assert_true("missing r9 fails", data == nil)
        M.assert_equal("missing kind", err.kind, "malformed")

        data, err = bridge_client.parse_measure_body(
            '{"cct":99999,"duv":0.008,"cri":72,"r9":42}')
        M.assert_true("cct range rejects", data == nil)
        M.assert_equal("cct validation kind", err.kind, "validation")
        M.assert_equal("cct validation msg", err.message, "cct_out_of_range")
    end

    M.section("parse_status_body – auth and last_error")
    do
        local body = read_fixture("bridge_status_ok.json")
        local data = bridge_client.parse_status_body(body)
        M.assert_true("status parsed", data ~= nil)
        M.assert_true("connected", data.connected)
        M.assert_false("auth_required default false", data.auth_required)

        local auth_body = body:gsub('"auth_required": false', '"auth_required": true')
        data = bridge_client.parse_status_body(auth_body)
        M.assert_true("auth_required true", data.auth_required)

        local err_body = body:gsub('"auth_required": false',
            '"auth_required": false, "last_error": "meter_not_found"')
        data = bridge_client.parse_status_body(err_body)
        M.assert_equal("last_error string", data.last_error, "meter_not_found")
    end

    M.section("classify_http – error kinds")
    do
        local r401 = bridge_client.classify_http(401,
            '{"error":"unauthorized","hint":"Send X-Bridge-Key header"}')
        M.assert_false("401 not ok", r401.ok)
        M.assert_equal("401 kind", r401.kind, "unauthorized")
        M.assert_equal("401 status", r401.http_status, 401)

        local r503 = bridge_client.classify_http(503, '{"error":"meter_not_connected"}')
        M.assert_equal("503 kind", r503.kind, "meter_unavailable")

        local r504 = bridge_client.classify_http(504, '{"error":"timeout"}')
        M.assert_equal("504 kind", r504.kind, "timeout")

        local r409 = bridge_client.classify_http(409, '{"error":"busy"}')
        M.assert_equal("409 kind", r409.kind, "busy")
    end
end
