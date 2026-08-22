-- DJI Mic 3 TX is HFP-only, and HFP's SCO link is bidirectional by spec, so
-- BlueZ always creates a sink beside the source. bluez.lua ignores
-- node.disabled and the adapter overrides media.class, so the only way to keep
-- the sink out of output pickers is to destroy the node as it appears.

sink_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "node.name", "=", "bluez_output.8C_58_23_B1_01_17.1" },
  }
}

sink_om:connect("object-added", function (om, node)
  Log.info (node, "destroying DJI Mic 3 HFP sink (input-only policy)")
  node:request_destroy ()
end)

sink_om:activate ()
