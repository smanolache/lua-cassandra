local utils = require "cassandra.utils.table"

--- Defaults
-- @section defaults

local DEFAULTS = {
  shm = "cassandra",
  contact_points = {},
  policies = {
    address_resolution = require "cassandra.policies.address_resolution",
    load_balancing = require("cassandra.policies.load_balancing").RoundRobin
  },
  protocol_options = {
    default_port = 9042
  },
  socket_options = {
    connect_timeout = 1000,
    read_timeout = 2000
  }
}

local function parse_session(options)
  if options == nil then options = {} end

  utils.extend_table(DEFAULTS, options)

  --if type(options.keyspace) ~= "string" then
    --error("keyspace must be a string")
  --end

  assert(type(options.protocol_options.default_port) == "number", "protocol default_port must be a number")
  assert(type(options.policies.address_resolution) == "function", "address_resolution policy must be a function")

  return options
end

local function parse_cluster(options)
  if options == nil then options = {} end

  parse_session(options)

  if type(options.contact_points) ~= "table" then
    error("contact_points must be a table", 3)
  end

  if not utils.is_array(options.contact_points) then
    error("contact_points must be an array (integer-indexed table)")
  end

  if #options.contact_points < 1 then
    error("contact_points must contain at least one contact point")
  end

  return options
end

return {
  parse_cluster = parse_cluster,
  parse_session = parse_session
}