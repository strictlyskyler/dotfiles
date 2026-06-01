@echo off
rem node-launcher.cmd - resolve a Node runtime at spawn time for the Honcho MCP
rem server. This is the Windows analogue of the POSIX `node-nvm` launcher: it is
rem referenced by a STABLE absolute path from %USERPROFILE%\.cursor\mcp.json so the
rem entry survives Node upgrades (a pinned vX.Y.Z path would dangle) and does not
rem depend on the spawning process having node on its PATH.
rem
rem All arguments (e.g. --preserve-symlinks-main <server.mjs>) are forwarded as-is.
setlocal

rem 1) Honor an explicit override.
if defined HONCHO_NODE_EXE if exist "%HONCHO_NODE_EXE%" (
  "%HONCHO_NODE_EXE%" %*
  exit /b %errorlevel%
)

rem 2) node on PATH (covers winget, nvm-windows shim, manual PATH edits).
for /f "delims=" %%I in ('where node 2^>nul') do (
  "%%I" %*
  exit /b %errorlevel%
)

rem 3) Common fixed install locations.
if exist "%ProgramFiles%\nodejs\node.exe" (
  "%ProgramFiles%\nodejs\node.exe" %*
  exit /b %errorlevel%
)
if exist "%LOCALAPPDATA%\Programs\nodejs\node.exe" (
  "%LOCALAPPDATA%\Programs\nodejs\node.exe" %*
  exit /b %errorlevel%
)

rem 4) nvm-windows: pick the highest installed version.
set "_NVM_HOME=%NVM_HOME%"
if not defined _NVM_HOME set "_NVM_HOME=%APPDATA%\nvm"
if exist "%_NVM_HOME%" (
  for /f "delims=" %%V in ('dir /b /ad /o-n "%_NVM_HOME%\v*" 2^>nul') do (
    if exist "%_NVM_HOME%\%%V\node.exe" (
      "%_NVM_HOME%\%%V\node.exe" %*
      exit /b %errorlevel%
    )
  )
)

echo node-launcher: could not locate a Node runtime (set HONCHO_NODE_EXE or install Node) 1>&2
exit /b 127
