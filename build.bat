@echo off
odin build src -out:camerashots.exe -o:speed -subsystem:windows -vet -vet-cast -resource:assets/app.rc
