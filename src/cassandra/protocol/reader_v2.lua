local utils = require "cassandra.utils"
local Object = require "cassandra.classic"
local cerror = require "cassandra.error"

local _M = Object:extend()

function _M:new(unmarshaller, constants)
  self.unmarshaller = unmarshaller
  self.constants = constants
end

function _M:read_error(buffer)
  local code = self.unmarshaller:read_int(buffer)
  local code_translation = self.constants.error_codes_translation[code]
  local message = self.unmarshaller:read_string(buffer)
  local formatted_message = string.format("Cassandra returned error (%s): %s", code_translation, message)
  return cerror(formatted_message, message, code)
end

-- Make a session listen for a response and decode the received frame
-- @param  `session`      The session on which to listen for a response.
-- @return `parsed_frame` The parsed frame ready to be read.
-- @return `err`          Any error encountered during the receiving.
function _M:receive_frame(session)
  local unmarshaller = self.unmarshaller

  local header, err = session.socket:receive(8)
  if not header then
    return nil, string.format("Failed to read frame header from %s:%s : %s", session.host, session.port, err)
  end
  local header_buffer = unmarshaller:create_buffer(header)
  local version = unmarshaller:read_raw_byte(header_buffer)
  if version ~= self.constants.version_codes.RESPONSE then
    return nil, string.format("Invalid response version received from %s:%s", session.host, session.port)
  end
  local flags = unmarshaller:read_raw_byte(header_buffer)
  local stream = unmarshaller:read_raw_byte(header_buffer)
  local op_code = unmarshaller:read_raw_byte(header_buffer)
  local length = unmarshaller:read_int(header_buffer)

  local body
  if length > 0 then
    body, err = session.socket:receive(length)
    if not body then
      return nil, string.format("Failed to read frame body from %s:%s : %s", session.host, session.port, err)
    end
  else
    body = ""
  end

  local body_buffer = unmarshaller:create_buffer(body)
  return {
    flags = flags,
    stream = stream,
    op_code = op_code,
    buffer = body_buffer
  }
end

local constants = require "cassandra.constants.constants_v2"
_M.result_kind_parsers = {
  [constants.result_kinds.VOID] = function()
    return {
      type = "VOID"
    }
  end,
  [constants.result_kinds.ROWS] = function(self, buffer)
    local metadata = self:parse_metadata(buffer)
    local result = self:parse_rows(buffer, metadata)
    result.type = "ROWS"
    result.meta = {
      has_more_pages = metadata.has_more_pages,
      paging_state = metadata.paging_state
    }
    return result
  end,
  [constants.result_kinds.PREPARED] = function(self, buffer)
    local id = self.unmarshaller:read_short_bytes(buffer)
    local metadata = self:parse_metadata(buffer)
    local result_metadata = self:parse_metadata(buffer)
    assert(buffer.pos == #(buffer.str) + 1)
    return {
      id = id,
      type = "PREPARED",
      metadata = metadata,
      result_metadata = result_metadata
    }
  end,
  [constants.result_kinds.SET_KEYSPACE] = function(self, buffer)
    return {
      type = "SET_KEYSPACE",
      keyspace = self.unmarshaller:read_string(buffer)
    }
  end,
  [constants.result_kinds.SCHEMA_CHANGE] = function(self, buffer)
    return  {
      type = "SCHEMA_CHANGE",
      change = self.unmarshaller:read_string(buffer),
      keyspace = self.unmarshaller:read_string(buffer),
      table = self.unmarshaller:read_string(buffer)
    }
  end
}

function _M:parse_response(response)
  local result, tracing_id

  -- Check if frame is an error
  if response.op_code == self.constants.op_codes.ERROR then
    return nil, self:read_error(response.buffer)
  end

  if response.flags == self.constants.flags.TRACING then
    tracing_id = self.unmarshaller:read_uuid(string.sub(response.buffer.str, 1, 16))
    response.buffer.pos = 17
  end

  local result_kind = self.unmarshaller:read_int(response.buffer)
  if _M.result_kind_parsers[result_kind] then
    result = _M.result_kind_parsers[result_kind](self, response.buffer)
  else
    return nil, string.format("Invalid result kind: %x", result_kind)
  end

  result.tracing_id = tracing_id
  return result
end

function _M:parse_column_type(buffer, column_name)
  return self.unmarshaller:read_option(buffer)
end

function _M:parse_metadata(buffer)
  -- Flags parsing
  local flags = self.unmarshaller:read_int(buffer)
  local global_tables_spec = utils.hasbit(flags, self.constants.rows_flags.GLOBAL_TABLES_SPEC)
  local has_more_pages = utils.hasbit(flags, self.constants.rows_flags.HAS_MORE_PAGES)
  local columns_count = self.unmarshaller:read_int(buffer)

  -- Potential paging metadata
  local paging_state
  if has_more_pages then
    paging_state = self.unmarshaller:read_bytes(buffer)
  end

  -- Potential global_tables_spec metadata
  local global_keyspace_name, global_table_name
  if global_tables_spec then
    global_keyspace_name = self.unmarshaller:read_string(buffer)
    global_table_name = self.unmarshaller:read_string(buffer)
  end

  -- Columns metadata
  local columns = {}
  for _ = 1, columns_count do
    local ksname = global_keyspace_name
    local tablename = global_table_name
    if not global_tables_spec then
      ksname = self.unmarshaller:read_string(buffer)
      tablename = self.unmarshaller:read_string(buffer)
    end
    local column_name = self.unmarshaller:read_string(buffer)
    local column_type = self:parse_column_type(buffer, column_name)
    columns[#columns + 1] = {
      name = column_name,
      type = column_type,
      table = tablename,
      keyspace = ksname
    }
  end

  return {
    columns = columns,
    paging_state = paging_state,
    columns_count = columns_count,
    has_more_pages = has_more_pages
  }
end

function _M:parse_rows(buffer, metadata)
  local columns = metadata.columns
  local columns_count = metadata.columns_count
  local rows_count = self.unmarshaller:read_int(buffer)
  local values = {}
  local row_mt = {
    __index = function(t, i)
      -- allows field access by position/index, not column name only
      local column = columns[i]
      if column then
        return t[column.name]
      end
      return nil
    end,
    __len = function() return columns_count end
  }
  for _ = 1, rows_count do
    local row = setmetatable({}, row_mt)
    for i = 1, columns_count do
      local value = self.unmarshaller:read_value(buffer, columns[i].type)
      row[columns[i].name] = value
    end
    values[#values + 1] = row
  end
  assert(buffer.pos == #(buffer.str) + 1)
  return values
end

return _M
