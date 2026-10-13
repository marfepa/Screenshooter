# Script de compilación y empaquetado para Windows
param (
    [string]$Configuration = "Release",
    [string]$Runtime = "win-x64",
    [string]$OutputDir = "./build"
)

$ErrorActionPreference = "Stop"

Write-Host "Compilando Screenshooter para Windows ($Runtime)..." -ForegroundColor Cyan

$PublishDir = "$OutputDir/publish"
if (Test-Path $PublishDir) {
    Remove-Item -Recurse -Force $PublishDir
}

dotnet publish "./Screenshooter.Windows/Screenshooter.Windows.csproj" `
    -c $Configuration `
    -r $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -o $PublishDir

Write-Host "Creando paquete zip portable..." -ForegroundColor Cyan
$ZipPath = "$OutputDir/Screenshooter-Windows-$Runtime.zip"
if (Test-Path $ZipPath) {
    Remove-Item -Force $ZipPath
}

Compress-Archive -Path "$PublishDir/*" -DestinationPath $ZipPath

Write-Host "¡Compilación completada con éxito en $ZipPath!" -ForegroundColor Green
