# frozen_string_literal: true

OmarchyUI.configure do
  type :plugin
  id "izeesoft.plugin-pulse"
  name "Plugin Pulse"
  slug "plugin-pulse"
  version "0.1.0"
  author "Adam Moussa Ali"
  license "MIT"
  description "Local runtime observability for enabled Omarchy plugins, their processes, reloads, source cues, and shell errors."
  entrypoint "main.rb"

  bar_widget do
    display_name "Plugin Pulse"
    description "See which plugins are actually loaded, what they launch, and where the shell is struggling."
    category "Developer Tools"
    default_section :right
  end
end
