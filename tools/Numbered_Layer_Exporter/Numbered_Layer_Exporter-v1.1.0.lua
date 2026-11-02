--[[
SEMTL Layer Exporter v1.1.0
For Aseprite v1.3.18.6 x64

Exports each non-reference layer as an individual image.
Features:
- Keep the original group folder structure, or flatten all exports.
- Optional global layer numbering (groups are never numbered).
- Ascending or descending numbering.
- Automatic zero-padding based on the number of exported layers.
- Export the current frame, a specific frame, or every frame.
- PNG, GIF or JPG output.
- Integer export scale.
- Destination folder is chosen with a folder browser, not a file dialog.

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

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isDirectory(path)
  if not path or path == "" then return false end
  local ok, result = pcall(function()
    return app.fs.isDirectory(path)
  end)
  return ok and result
end

local function dirname(path)
  if not path or path == "" then return nil end
  local normalized = path:gsub("[\\/]+$", "")
  local result = normalized:match("^(.*)[\\/][^\\/]+$")
  if result == "" then
    return path:sub(1, 1)
  end
  -- Preserve the trailing separator for Windows drive roots (for example C:\).
  if result and result:match("^%a:$") then
    return result .. (path:find("\\", 1, true) and "\\" or "/")
  end
  return result
end

local function parentFolder(path)
  local p = tostring(path or ""):gsub("[\\/]+$", "")
  if p == "" then
    return app.fs.pathSeparator
  end
  if p:match("^%a:$") then
    return p .. app.fs.pathSeparator
  end
  local parent = p:match("^(.*)[\\/][^\\/]+$")
  if not parent or parent == "" then
    return p
  end
  if parent:match("^%a:$") then
    return parent .. app.fs.pathSeparator
  end
  return parent
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
-- Folder picker
-- ---------------------------------------------------------------------------

local function listSubfolders(path)
  local folders = {}
  local ok, files = pcall(function()
    return app.fs.listFiles(path)
  end)
  if not ok or type(files) ~= "table" then
    return folders
  end

  for _, name in ipairs(files) do
    local fullPath = app.fs.joinPath(path, name)
    if isDirectory(fullPath) then
      folders[#folders + 1] = name
    end
  end

  table.sort(folders, function(a, b)
    return a:lower() < b:lower()
  end)

  return folders
end

local function confirmCreateFolder(path)
  local dlg = Dialog("Crear carpeta")
  dlg:label {
    text = "La carpeta no existe:\n" .. path .. "\n\n¿Quieres crearla?"
  }
  dlg:button { id = "create", text = "Crear" }
  dlg:button { id = "cancel", text = "Cancelar" }
  dlg:show()
  return dlg.data.create == true
end

local function askNewFolderName(baseFolder)
  local dlg = Dialog("Nueva carpeta")
  dlg:label { text = "Se creará dentro de:\n" .. baseFolder }
  dlg:entry { id = "name", label = "Nombre:", text = "", focus = true }
  dlg:button { id = "create", text = "Crear" }
  dlg:button { id = "cancel", text = "Cancelar" }
  dlg:show()

  if not dlg.data.create then return nil end

  local name = trim(dlg.data.name)
  if name == "" or name == "." or name == ".." then
    return nil
  end
  return sanitizeName(name)
end

local function chooseFolder(startPath)
  local current = trim(startPath)
  if not isDirectory(current) then
    current = app.fs.userDocsPath
    if not isDirectory(current) then
      current = app.fs.currentPath
    end
  end

  while true do
    local folders = listSubfolders(current)

    local upLabel = ".. (subir un nivel)"
    local options = { upLabel }
    for _, name in ipairs(folders) do
      options[#options + 1] = name
    end

    local dlg = Dialog("Elegir carpeta de destino")
    dlg:entry { id = "path", label = "Carpeta:", text = current, focus = true }
    dlg:combobox {
      id = "subfolder",
      label = "Subcarpetas:",
      option = options[1],
      options = options
    }
    dlg:button { id = "open", text = "Abrir" }
    dlg:button { id = "up", text = "Subir" }
    dlg:button { id = "new", text = "Nueva carpeta..." }
    dlg:newrow { always = true }
    dlg:button { id = "choose", text = "Usar esta carpeta", focus = true }
    dlg:button { id = "cancel", text = "Cancelar" }
    dlg:show()

    local typed = trim(dlg.data.path)
    local pressed = nil
    for _, id in ipairs({ "open", "up", "new", "choose", "cancel" }) do
      if dlg.data[id] then
        pressed = id
        break
      end
    end

    if pressed == nil or pressed == "cancel" then
      return nil

    elseif pressed == "choose" then
      if typed == "" then
        typed = current
      end
      if isDirectory(typed) then
        return app.fs.normalizePath(typed)
      elseif confirmCreateFolder(typed) then
        if ensureDirectory(typed) then
          return app.fs.normalizePath(typed)
        end
        showMessage("SEMTL Layer Exporter", "No se pudo crear la carpeta:\n" .. typed)
      end

    elseif pressed == "up" then
      current = parentFolder(current)

    elseif pressed == "open" then
      if typed ~= "" and typed ~= current and isDirectory(typed) then
        current = typed
      else
        local selected = dlg.data.subfolder
        if selected == upLabel then
          current = parentFolder(current)
        elseif selected and selected ~= "" then
          current = app.fs.joinPath(current, selected)
        end
      end

    elseif pressed == "new" then
      local name = askNewFolderName(current)
      if name then
        local newPath = app.fs.joinPath(current, name)
        if ensureDirectory(newPath) then
          current = newPath
        else
          showMessage("SEMTL Layer Exporter", "No se pudo crear la carpeta:\n" .. newPath)
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Layer collection and visibility
-- ---------------------------------------------------------------------------

local function collectLayers(parent, groupNames, groupObjects, result)
  for _, layer in ipairs(parent.layers) do
    if layer.isGroup then
      local names = {}
      for i, name in ipairs(groupNames) do names[i] = name end
      names[#names + 1] = layer.name

      local objects = {}
      for i, group in ipairs(groupObjects) do objects[i] = group end
      objects[#objects + 1] = layer

      collectLayers(layer, names, objects, result)
    elseif not layer.isReference then
      local names = {}
      for i, name in ipairs(groupNames) do names[i] = name end

      local objects = {}
      for i, group in ipairs(groupObjects) do objects[i] = group end

      result[#result + 1] = {
        layer = layer,
        groupNames = names,
        groups = objects
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
  for _, group in ipairs(entry.groups) do
    group.isVisible = true
  end
end

-- ---------------------------------------------------------------------------
-- Main dialog
-- ---------------------------------------------------------------------------

if not sprite then
  showMessage("SEMTL Layer Exporter", "No hay ningún sprite abierto. Abre un archivo antes de ejecutar el exportador.")
  return
end

local currentFrameNumber = 1
if app.frame then
  currentFrameNumber = app.frame.frameNumber
elseif app.activeFrame then
  currentFrameNumber = app.activeFrame.frameNumber
end

local defaultFolder = ""
if sprite.filename and sprite.filename ~= "" then
  defaultFolder = app.fs.filePath(sprite.filename)
end
if not defaultFolder or defaultFolder == "" then
  defaultFolder = app.fs.userDocsPath
end
if not defaultFolder or defaultFolder == "" then
  defaultFolder = app.fs.currentPath
end

local dlg = Dialog("SEMTL Layer Exporter")

dlg:entry {
  id = "outputFolder",
  label = "Carpeta de salida:",
  text = defaultFolder
}

dlg:newrow { always = true }

dlg:button {
  id = "browse",
  text = "Elegir carpeta...",
  onclick = function()
    local chosen = chooseFolder(dlg.data.outputFolder)
    if chosen then
      dlg:modify { id = "outputFolder", text = chosen }
    end
  end
}

dlg:separator()

dlg:combobox {
  id = "frameMode",
  label = "Fotogramas:",
  option = "Fotograma actual",
  options = { "Fotograma actual", "Todos los fotogramas", "Elegir un fotograma..." },
  onchange = function()
    local showNumber = dlg.data.frameMode == "Elegir un fotograma..."
    dlg:modify { id = "frameNumber", visible = showNumber, enabled = showNumber }
  end
}

dlg:number {
  id = "frameNumber",
  label = "Número de fotograma:",
  text = tostring(currentFrameNumber)
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

-- The frame number field is only relevant for the "pick one" mode.
dlg:modify { id = "frameNumber", visible = false, enabled = false }

dlg:show()

if not dlg.data.export then
  return
end

-- ---------------------------------------------------------------------------
-- Validate destination and prepare export list
-- ---------------------------------------------------------------------------

local outputRoot = trim(dlg.data.outputFolder)
if outputRoot == "" then
  showMessage("SEMTL Layer Exporter", "Selecciona una carpeta de destino válida.")
  return
end

if not isDirectory(outputRoot) then
  if not ensureDirectory(outputRoot) then
    showMessage("SEMTL Layer Exporter", "No se pudo crear o acceder a la carpeta de destino:\n" .. outputRoot)
    return
  end
end

outputRoot = app.fs.normalizePath(outputRoot)
local separator = app.fs.pathSeparator

-- Resolve the frames to export before building the file list.
local frameNumbers = {}
local frameMode = dlg.data.frameMode

if frameMode == "Todos los fotogramas" then
  for i = 1, #sprite.frames do
    frameNumbers[#frameNumbers + 1] = i
  end
elseif frameMode == "Elegir un fotograma..." then
  local frameNumber = tonumber(dlg.data.frameNumber)
  if not frameNumber or frameNumber % 1 ~= 0
     or frameNumber < 1 or frameNumber > #sprite.frames then
    showMessage(
      "SEMTL Layer Exporter",
      "El número de fotograma debe estar entre 1 y " .. #sprite.frames .. "."
    )
    return
  end
  frameNumbers[1] = frameNumber
else
  frameNumbers[1] = currentFrameNumber
end

if #frameNumbers == 0 then
  showMessage("SEMTL Layer Exporter", "No hay fotogramas para exportar.")
  return
end

local entries = {}
collectLayers(sprite, {}, {}, entries)

if #entries == 0 then
  showMessage("SEMTL Layer Exporter", "No se encontraron capas exportables. Las capas de referencia se omiten.")
  return
end

local numbering = dlg.data.numberLayers
local descending = dlg.data.numberOrder == "Descendente"
local digitCount = math.max(2, #tostring(math.max(0, #entries - 1)))
local frameDigits = math.max(2, #tostring(#sprite.frames))
local multipleFrames = #frameNumbers > 1
local extension = "." .. dlg.data.format
local usedPaths = {}
local exportList = {}

for index, entry in ipairs(entries) do
  local number = index - 1
  if descending then
    number = #entries - index
  end

  local numberText = nil
  if numbering then
    numberText = string.format("%0" .. digitCount .. "d", number)
  end

  local folderPath = outputRoot
  if dlg.data.keepFolders then
    for _, groupName in ipairs(entry.groupNames) do
      folderPath = joinPath(folderPath, sanitizeName(groupName), separator)
    end
  end

  local layerName = sanitizeName(entry.layer.name)

  for _, frameNumber in ipairs(frameNumbers) do
    local filename = layerName

    if numbering then
      filename = numberText .. "-" .. filename
    end

    -- Only add a frame suffix when more than one frame is exported, so the
    -- single-frame output keeps the same names as previous versions.
    if multipleFrames then
      filename = filename .. "_f" .. string.format("%0" .. frameDigits .. "d", frameNumber)
    end

    local fullPath = joinPath(folderPath, filename .. extension, separator)
    fullPath = uniqueFilePath(fullPath, usedPaths)

    exportList[#exportList + 1] = {
      layer = entry.layer,
      groups = entry.groups,
      frame = frameNumber,
      path = fullPath
    }
  end
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------

local scale = dlg.data.scale
local originalVisibility = {}
saveVisibility(sprite, originalVisibility)

local exported = 0
local currentFile = nil
local failure = nil

local ok, err = pcall(function()
  local exportLayerName = nil

  for _, item in ipairs(exportList) do
    currentFile = item.path

    local folder = dirname(item.path)
    if not ensureDirectory(folder) then
      error("No se pudo crear la carpeta:\n" .. tostring(folder))
    end

    -- Visibility only needs to be recalculated when the layer changes.
    if exportLayerName ~= item.layer then
      hideEverything(sprite)
      showLayerAndParents(item)
      exportLayerName = item.layer
    end

    local image = Image(sprite.spec)
    image:drawSprite(sprite, item.frame)

    if scale ~= 1 then
      image:resize {
        width = image.width * scale,
        height = image.height * scale
      }
    end

    local saved, saveResult
    if sprite.colorMode == ColorMode.INDEXED then
      saved, saveResult = pcall(function()
        return image:saveAs { filename = item.path, palette = sprite.palettes[1] }
      end)
    else
      saved, saveResult = pcall(function()
        return image:saveAs(item.path)
      end)
    end

    if not saved or saveResult == false then
      error("Aseprite no pudo guardar:\n" .. item.path)
    end

    exported = exported + 1
  end
end)

-- Always restore the original document state, even if an export failed.
pcall(function()
  restoreVisibility(originalVisibility)
end)

if not ok then
  failure = tostring(err)
end

if failure then
  local message = "La exportación se detuvo después de " .. exported .. " de " .. #exportList .. " archivos.\n\n"
  message = message .. failure
  if currentFile then
    message = message .. "\n\nArchivo en proceso:\n" .. currentFile
  end
  showMessage("SEMTL Layer Exporter - Error", message)
else
  local message = "Exportación completada.\n\n"
  message = message .. "Archivos exportados: " .. exported .. "\n"
  message = message .. "Capas: " .. #entries .. "\n"
  message = message .. "Fotogramas por capa: " .. #frameNumbers .. "\n"
  message = message .. "Carpeta:\n" .. outputRoot
  showMessage("SEMTL Layer Exporter", message)
end
