-- Host tests for lua/config.lua (path helpers + config parse)

return function(M)
    print("\n--- config.lua ---")
    local config = require("config")

    M.assert_equal("normalize macOS plugin dir",
        config.normalize_plugin_dir("/Users/op/MALightingTechnology/gma3_library/datapools/plugins", "macOS", "/"),
        "/Users/op/MALightingTechnology/gma3_library/datapools/plugins/SekonicCalibrator")

    M.assert_equal("normalize Windows plugin dir",
        config.normalize_plugin_dir("C:\\Users\\op\\AppData\\Roaming\\MALightingTechnology\\gma3_library\\datapools\\plugins", "Windows", "\\"),
        "C:\\Users\\op\\AppData\\Roaming\\MALightingTechnology\\gma3_library\\datapools\\plugins\\SekonicCalibrator")

    local sample = [[{
  "github_username": "testuser",
  "bridge_ip": "127.0.0.1",
  "bridge_port": 8765,
  "bridge_api_key": "secret"
}]]
    local parsed = config.parse_config_content(sample)
    M.assert_true("parse_config_content returns table", type(parsed) == "table")
    M.assert_equal("parse bridge_ip", parsed.bridge_ip, "127.0.0.1")
    M.assert_equal("parse bridge_port", parsed.bridge_port, 8765)
    M.assert_equal("parse github_username", parsed.github_username, "testuser")
    M.assert_equal("parse bridge_api_key", parsed.bridge_api_key, "secret")

    local defaults = config.parse_config_content('{"bridge_ip":"10.0.0.5"}')
    M.assert_equal("default bridge_port when omitted", defaults.bridge_port, 8765)
end
