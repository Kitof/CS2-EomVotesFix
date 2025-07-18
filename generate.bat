@echo off

set "cur_path=%cd%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -Verb RunAs powershell -ArgumentList '-NoExit -NoProfile -ExecutionPolicy Bypass -File \"%cur_path%\bin\create_endofmatch_workshop_thumbnail.ps1\" -WorkingDir \"%cur_path%\"'"