--[[
SEMTL Layer Exporter v1.0.0
For Aseprite v1.3.18.6 x64

Exports each non-reference layer as an individual image.
Features:
- Keep the original group folder structure, or flatten all exports.
- Optional global layer numbering (groups are never numbered).
- Ascending or descending numbering.
- Automatic zero-padding based on the number of exported layers.
- PNG, GIF or JPG output.
- Integer export scale.

This script is independent from Gaspi's main.lua and other scripts.
]]

local sprite = app.activeSprite

-- ---------------------------------------------------------------------------
-- General helpers
-- ---------------------------------------------------------------------------

local function showMessage(title, message)
  local dlg = Dialog(title)
  dlg:label { text = message }
  dlg:button { text = "Aceptar", onclick = function() dlg:close() end }
  dlg:show()
end

local function getSeparator(path)
  if string.find(path or "", "\\", 1, true) then
    return "\\"
  end
  return "/"
end

local function dirname(path)
  if not path or path == "" then return nil end
  local normalized = path:gsub("[\\/]+$", "")
  local result = normalized:match("^(.*)[\\/][^\\/]+$")
  if result == "" then
    return path:sub(1, 1)
  end
  -- Preserve the trailing separator for Windows drive roots (for example C:\).
  if result:match("^%a:$") then
    return result .. (path:find("\\", 1, true) and "\\" or "/")
  end
  return result
end

local function sanitizeName(name)
  -- Keep names readable while preventing characters that are invalid in
  -- Windows filenames. Slashes are also replaced so layer names stay files.
  local clean = tostring(name or ""):gsub('[<>:"/\\|%?%*]', "_")
  clean = clean:gsub("[%c]", "_")
  clean = clean:gsub("[%. ]+$", "")
  if clean == "" then clean = "Capa" end
  return clean
end

local function joinPath(left, right, sep)
  if left == "" then return right end
  if left:sub(-1) == "/" or left:sub(-1) == "\\" then
    return left .. right
  end
  return left .. sep .. right
end

local function ensureDirectory(path)
  if not path or path == "" then return false end

  local ok, isDir = pcall(function()
    return app.fs.isDirectory(path)
  end)
  if ok and isDir then return true end

  local parent = dirname(path)
  if parent and parent ~= path then
    local parentOk, parentIsDir = pcall(function()
      return app.fs.isDirectory(parent)
    end)
    if not parentOk or not parentIsDir then
      if not ensureDirectory(parent) then return false end
    end
  end

  local made, result = pcall(function()
    return app.fs.makeDirectory(path)
  end)
  if not made then return false end

  local checkOk, checkIsDir = pcall(function()
    return app.fs.isDirectory(path)
  end)
  return checkOk and checkIsDir
end

local function fileExists(path)
  local ok, result = pcall(function()
    return app.fs.isFile(path)
  end)
  return ok and result
end

local function uniqueFilePath(path, usedPaths)
  if not usedPaths[path] and not fileExists(path) then
    usedPaths[path] = true
    return path
  end

  local base, extension = path:match("^(.*)(%.[^%.]+)$")
  if not base then
    base, extension = path, ""
  end

  local suffix = 2
  local candidate = base .. "_" .. suffix .. extension
  while usedPaths[candidate] or fileExists(candidate) do
    suffix = suffix + 1
    candidate = base .. "_" .. suffix .. extension
  end

  usedPaths[candidate] = true
  return candidate
end

-- ---------------------------------------------------------------------------
-- Layer collection and visibility
-- ---------------------------------------------------------------------------

local function collectLayers(parent, parentGroups, result)
  for _, layer in ipairs(parent.layers) do
    if layer.isGroup then
      local groups = {}
      for i, groupName in ipairs(parentGroups) do
        groups[i] = groupName
      end
      groups[#groups + 1] = layer.name
      collectLayers(layer, groups, result)
    elseif not layer.isReference then
      local groups = {}
      for i, groupName in ipairs(parentGroups) do
        groups[i] = groupName
      end
      result[#result + 1] = {
        layer = layer,
        groups = groups
      }
    end
  end
end

local function saveVisibility(parent, data)
  for i, layer in ipairs(parent.layers) do
    data[i] = {
      layer = layer,
      visible = layer.isVisible
    }
    if layer.isGroup then
      data[i].children = {}
      saveVisibility(layer, data[i].children)
    end
  end
end

local function restoreVisibility(data)
  for _, item in ipairs(data) do
    item.layer.isVisible = item.visible
    if item.children then
      restoreVisibility(item.children)
    end
  end
end

local function hideEverything(parent)
  for _, layer in ipairs(parent.layers) do
    layer.isVisible = false
    if layer.isGroup then
      hideEverything(layer)
    end
  end
end

local function showLayerAndParents(entry)
  entry.layer.isVisible = true
  -- A group must be visible for its child layer to appear in the export.
  -- Groups are stored from outermost to innermost.
  -- The parent references are collected separately below.
  for _, group in ipairs(entry.groups) do
    group.isVisible = true
  end
end

-- ---------------------------------------------------------------------------
-- Dialog
-- ---------------------------------------------------------------------------

if not sprite then
  showMessage("SEMTL Layer Exporter", "No hay ningún sprite abierto. Abre un archivo antes de ejecutar el exportador.")
  return
end

local defaultPath = sprite.filename or ""
local dlg = Dialog("SEMTL Layer Exporter")

dlg:file {
  id = "destination",
  label = "Ubicación de salida (elige un nombre dentro de la carpeta):",
  filename = defaultPath,
  open = false
}

dlg:check {
  id = "keepFolders",
  label = "Conservar carpetas de grupos",
  selected = false
}

dlg:check {
  id = "numberLayers",
  label = "Numerar capas",
  selected = true,
  onclick = function()
    dlg:modify {
      id = "numberOrder",
      visible = dlg.data.numberLayers
    }
  end
}

dlg:combobox {
  id = "numberOrder",
  label = "Orden:",
  option = "Ascendente",
  options = { "Ascendente", "Descendente" }
}

dlg:combobox {
  id = "format",
  label = "Formato:",
  option = "png",
  options = { "png", "gif", "jpg" }
}

dlg:slider {
  id = "scale",
  label = "Escala:",
  min = 1,
  max = 10,
  value = 1
}

dlg:button { id = "export", text = "Exportar" }
dlg:button { id = "cancel", text = "Cancelar" }
dlg:show()

if not dlg.data.export then
  return
end

-- ---------------------------------------------------------------------------
-- Validate destination and prepare export list
-- ---------------------------------------------------------------------------

local selectedPath = dlg.data.destination
local outputRoot = dirname(selectedPath)

if not outputRoot then
  showMessage("SEMTL Layer Exporter", "Selecciona una carpeta de destino válida.")
  return
end

local separator = getSeparator(selectedPath)
local entries = {}
collectLayers(sprite, {}, entries)

if #entries == 0 then
  showMessage("SEMTL Layer Exporter", "No se encontraron capas exportables. Las capas de referencia se omiten.")
  return
end

if not ensureDirectory(outputRoot) then
  showMessage("SEMTL Layer Exporter", "No se pudo crear o acceder a la carpeta de destino:\n" .. outputRoot)
  return
end

local numbering = dlg.data.numberLayers
local descending = dlg.data.numberOrder == "Descendente"
local digitCount = math.max(2, #tostring(math.max(0, #entries - 1)))
local extension = "." .. dlg.data.format
local usedPaths = {}
local exportList = {}

for index, entry in ipairs(entries) do
  local number = index - 1
  if descending then
    number = #entries - index
  end

  local layerName = sanitizeName(entry.layer.name)
  local filename = layerName

  if numbering then
    local numberText = string.format("%0" .. digitCount .. "d", number)
    filename = numberText .. "-" .. filename
  end

  local folderPath = outputRoot
  if dlg.data.keepFolders then
    for _, groupName in ipairs(entry.groups) do
      folderPath = joinPath(folderPath, sanitizeName(groupName), separator)
    end
  end

  local fullPath = joinPath(folderPath, filename .. extension, separator)
  fullPath = uniqueFilePath(fullPath, usedPaths)

  exportList[#exportList + 1] = {
    layer = entry.layer,
    groups = entry.groups,
    path = fullPath
  }
end

-- Build direct group references for visibility toggling.
-- collectLayers stores group names for paths; this helper resolves the actual
-- group objects so duplicate group names at different levels remain safe.
local function collectLayersWithParents(parent, parents, result)
  for _, layer in ipairs(parent.layers) do
    if layer.isGroup then
      local nextParents = {}
      for i, group in ipairs(parents) do nextParents[i] = group end
      nextParents[#nextParents + 1] = layer
      collectLayersWithParents(layer, nextParents, result)
    elseif not layer.isReference then
      result[#result + 1] = {
        layer = layer,
        groups = parents
      }
    end
  end
end

local resolvedEntries = {}
collectLayersWithParents(sprite, {}, resolvedEntries)

-- The collection order is identical in both traversals. Attach parent objects.
for i, item in ipairs(exportList) do
  item.groups = resolvedEntries[i].groups
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

local originalWidth = sprite.width
local originalHeight = sprite.height
local originalVisibility = {}
saveVisibility(sprite, originalVisibility)

local exported = 0
local currentFile = nil
local failure = nil

local transactionOk, transactionError = pcall(function()
  app.transaction("SEMTL Layer Exporter", function()
    local operationOk, operationError = pcall(function()
      local scale = dlg.data.scale
      if scale ~= 1 then
        sprite:resize(originalWidth * scale, originalHeight * scale)
      end

      hideEverything(sprite)

      for _, item in ipairs(exportList) do
        currentFile = item.path
        local folder = dirname(item.path)

        if not ensureDirectory(folder) then
          error("No se pudo crear la carpeta:\n" .. tostring(folder))
        end

        hideEverything(sprite)
        showLayerAndParents(item)

        local saved, saveResult = pcall(function()
          return sprite:saveCopyAs(item.path)
        end)

        if not saved or saveResult == false then
          error("Aseprite no pudo guardar:\n" .. item.path)
        end

        exported = exported + 1
      end
    end)

    -- Always restore the original document state before the transaction ends.
    restoreVisibility(originalVisibility)
    if sprite.width ~= originalWidth or sprite.height ~= originalHeight then
      sprite:resize(originalWidth, originalHeight)
    end

    if not operationOk then
      failure = tostring(operationError)
    end
  end)
end)

-- Remove the temporary resize/visibility changes from the document history.
-- The document was already restored explicitly above.
if transactionOk then
  pcall(function() app.undo() end)
else
  -- If the transaction itself failed, make a best-effort restoration.
  pcall(function()
    restoreVisibility(originalVisibility)
    if sprite.width ~= originalWidth or sprite.height ~= originalHeight then
      sprite:resize(originalWidth, originalHeight)
    end
  end)
  failure = failure or tostring(transactionError)
end

if failure then
  local message = "La exportación se detuvo después de " .. exported .. " de " .. #exportList .. " capas.\n\n"
  message = message .. failure
  if currentFile then
    message = message .. "\n\nArchivo en proceso:\n" .. currentFile
  end
  showMessage("SEMTL Layer Exporter - Error", message)
else
  showMessage(
    "SEMTL Layer Exporter",
    "Exportación completada.\n\nCapas exportadas: " .. exported .. "\nCarpeta:\n" .. outputRoot
  )
end
