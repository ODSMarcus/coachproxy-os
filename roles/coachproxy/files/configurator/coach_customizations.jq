# coach_customizations.jq
# Hand customizations of this coach's flow, applied by cp_config.pl as the
# last step of every configurator run so that re-running the configurator
# reproduces the live flow instead of wiping them.
#
# Matched by the template's node IDs, which the configurator keeps.

map(
  # Light 7 is the Office, not the Dinette.
  if .id == "de5083f5.8f342" then .label = "Office"

  # Retract the awnings for 35 seconds instead of 25.
  elif .id == "3ae40612.fcd9ba" or .id == "eae4bba1.07a368" then
    .payload |= sub("--duration=[0-9]+"; "--duration=35")

  # Awning safety toggle: enable/disable the buttons directly, and turn the
  # toggle back off after 5 seconds instead of 61.
  elif .id == "545151d.88d37b" then .wires = [["6c6f024f.b3a9fc", "34a060d9.0980a"]]
  elif .id == "34a060d9.0980a" then
    .duration = "5" | .topic = "topic" | .overrideDelay = false | .outputs = 1
    | .wires = [["6c6f024f.b3a9fc", "9f99c76e.b8e8c8"]]

  # Dashboard theme colours.
  elif .type == "ui_base" then .theme = {"name":"theme-custom","lightTheme":{"default":"#0094CE","baseColor":"#0094CE","baseFont":"-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen-Sans,Ubuntu,Cantarell,Helvetica Neue,sans-serif","edited":true,"reset":false},"darkTheme":{"default":"#097479","baseColor":"#169dd3","baseFont":"-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen-Sans,Ubuntu,Cantarell,Helvetica Neue,sans-serif","edited":true,"reset":false},"customTheme":{"default":"#4B7930","baseColor":"#3d89be","baseFont":"-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen-Sans,Ubuntu,Cantarell,Helvetica Neue,sans-serif","reset":false},"themeState":{"base-color":{"default":"#3d89be","value":"#3d89be","edited":false},"page-titlebar-backgroundColor":{"value":"#3d89be","edited":true},"page-backgroundColor":{"value":"#fafafa","edited":true},"page-sidebar-backgroundColor":{"value":"#ffffff","edited":false},"group-textColor":{"value":"#75acd3","edited":true},"group-borderColor":{"value":"#ffffff","edited":false},"group-backgroundColor":{"value":"#ffffff","edited":false},"widget-textColor":{"value":"#111111","edited":false},"widget-backgroundColor":{"value":"#3d89be","edited":true},"widget-borderColor":{"value":"#ffffff","edited":false},"base-font":{"value":"-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen-Sans,Ubuntu,Cantarell,Helvetica Neue,sans-serif"}},"angularTheme":{"primary":"indigo","accents":"blue","warn":"red","background":"grey","palette":"light"}}

  else . end
)
# The node that feeds the 5-second timer back to the awning toggle.
| if any(.[]; .id == "9f99c76e.b8e8c8") then . else . + [{"id":"9f99c76e.b8e8c8","type":"switch","z":"5a05b8f3.894b88","name":"","property":"payload","propertyType":"msg","rules":[{"t":"true"},{"t":"false"}],"checkall":"true","repair":false,"outputs":2,"x":3170,"y":2620,"wires":[["545151d.88d37b"],["545151d.88d37b"]]}] end
