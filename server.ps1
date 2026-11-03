param([switch]$NoBrowser)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $root ".env"
$apiKey = ""

if (Test-Path -LiteralPath $envPath) {
  Get-Content -LiteralPath $envPath -Encoding UTF8 | ForEach-Object {
    if ($_ -match '^\s*OPENAI_API_KEY\s*=\s*(.+?)\s*$') {
      $apiKey = $Matches[1].Trim().Trim('"').Trim("'")
    }
  }
}

function Write-Json($context, $status, $obj) {
  $json = $obj | ConvertTo-Json -Depth 8 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  $context.Response.StatusCode = $status
  $context.Response.ContentType = "application/json; charset=utf-8"
  $context.Response.ContentLength64 = $bytes.Length
  $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $context.Response.OutputStream.Close()
}

function Read-Body($request) {
  $reader = New-Object IO.StreamReader($request.InputStream, [Text.Encoding]::UTF8)
  try { return $reader.ReadToEnd() } finally { $reader.Close() }
}

function Get-ApiError($err) {
  $detail = $err.ErrorDetails.Message
  if (-not $detail -and $err.Exception.Response) {
    try {
      $stream = $err.Exception.Response.GetResponseStream()
      $reader = New-Object IO.StreamReader($stream)
      $detail = $reader.ReadToEnd()
      $reader.Close()
    } catch { }
  }
  if (-not $detail) { $detail = $err.Exception.Message }
  $detail = [string]$detail
  $detail = $detail -replace 'sk-[A-Za-z0-9_\-]+', '[key]'
  return $detail
}

function Invoke-OpenAI($model, $system, $messages) {
  $payload = @{
    model = $model
    temperature = 0.8
    max_tokens = 500
    response_format = @{ type = "json_object" }
    messages = @(@{ role = "system"; content = $system }) + @($messages)
  }
  $body = $payload | ConvertTo-Json -Depth 8
  $headers = @{ Authorization = "Bearer $apiKey" }
  return Invoke-RestMethod -Method Post -Uri "https://api.openai.com/v1/chat/completions" -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body
}

function New-SystemPrompt($mode, $level, $topic) {
  $topicLine = "No specific topic yet."
  if ($topic) { $topicLine = "Current topic: $topic." }
  @"
You are Mia, a warm English conversation partner for a Korean learner.
Speak only English in reply. Sound like a person, not a worksheet.
Mode: $mode.
Level: $level.
$topicLine
Friend mode: casual, curious, short. Tutor mode: clear sentences, still conversational. Interview mode: you are interviewing them for a job at a small cafe company. Ask one interview question at a time and stay in that scene.
Match the level. Beginner: simple words and short sentences. Intermediate: natural everyday English. Advanced: fuller opinions and a richer vocabulary.
Return a JSON object with this shape:
{"reply":"string","suggestions":["string","string"],"correction":null}
reply is 2 to 4 sentences and usually ends with one question. Keep it under 70 words.
suggestions are two short English lines the learner could send next, at their level.
correction is null when their latest message is already natural.
When it needs help, correction is {"natural":"their message rewritten in natural English","notes":["short Korean explanation","optional second note"]}.
Notes are Korean, one clause each, and only for real grammar or unnatural phrasing.
Do not correct capitalization or a missing final period alone.
"@
}

function Convert-Mia($response) {
  $text = [string]$response.choices[0].message.content
  $reply = $text
  $suggestions = @()
  $correction = $null
  try {
    $parsed = $text | ConvertFrom-Json
    if ($parsed.reply) { $reply = [string]$parsed.reply }
    if ($parsed.suggestions) { $suggestions = @($parsed.suggestions | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
    if ($parsed.correction -and $parsed.correction.natural) {
      $notes = @()
      if ($parsed.correction.notes) {
        $notes = @($parsed.correction.notes | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -First 3)
      }
      $correction = @{ natural = [string]$parsed.correction.natural; notes = $notes }
    }
  } catch { }
  if ($suggestions.Count -gt 2) { $suggestions = @($suggestions | Select-Object -First 2) }
  return @{ reply = $reply.Trim(); suggestions = @($suggestions); correction = $correction }
}

$listener = $null
$port = 0
foreach ($candidate in 8765, 8766, 8770) {
  $tryListener = New-Object System.Net.HttpListener
  $tryListener.Prefixes.Add("http://127.0.0.1:$candidate/")
  try {
    $tryListener.Start()
    $listener = $tryListener
    $port = $candidate
    break
  } catch {
    $tryListener.Close()
  }
}

if (-not $listener) {
  Write-Output "Could not open a local port."
  exit 1
}

$url = "http://127.0.0.1:$port/"
Write-Output "FreeTalk $url"
if (-not $apiKey) { Write-Output "OPENAI_API_KEY was not found in .env" }
if (-not $NoBrowser) { Start-Process $url }

while ($listener.IsListening) {
  $context = $listener.GetContext()
  try {
    $path = $context.Request.Url.LocalPath
    if ($path -eq "/api/health") {
      Write-Json $context 200 @{ ok = $true; configured = [bool]$apiKey }
      continue
    }

    if ($path -eq "/api/chat" -and $context.Request.HttpMethod -eq "POST") {
      if (-not $apiKey) {
        Write-Json $context 500 @{ error = "missing_api_key" }
        continue
      }
      $raw = Read-Body $context.Request
      $inputObj = $raw | ConvertFrom-Json
      $mode = [string]$inputObj.mode
      $level = [string]$inputObj.level
      $topic = [string]$inputObj.topic
      if ($mode -notin @("friend", "tutor", "interview")) { $mode = "friend" }
      if ($level -notin @("beginner", "intermediate", "advanced")) { $level = "beginner" }
      if ($topic.Length -gt 40) { $topic = $topic.Substring(0, 40) }

      $messages = @()
      foreach ($message in @($inputObj.messages)) {
        $role = [string]$message.role
        $content = [string]$message.content
        if ($role -notin @("user", "assistant")) { continue }
        if ([string]::IsNullOrWhiteSpace($content)) { continue }
        if ($content.Length -gt 2000) { $content = $content.Substring(0, 2000) }
        $messages += @{ role = $role; content = $content }
      }
      if ($messages.Count -gt 24) { $messages = @($messages | Select-Object -Last 24) }
      if (-not $messages.Count) {
        Write-Json $context 400 @{ error = "empty_messages" }
        continue
      }

      $system = New-SystemPrompt $mode $level $topic
      $response = $null
      $apiError = ""
      foreach ($model in @("gpt-4.1-mini", "gpt-4o-mini")) {
        try {
          $response = Invoke-OpenAI $model $system $messages
          break
        } catch {
          $apiError = Get-ApiError $_
          if ($apiError -match '401|invalid_api_key|Incorrect API key') { break }
          if ($apiError -notmatch 'model') { break }
        }
      }
      if (-not $response) {
        Write-Output "OpenAI request failed"
        Write-Json $context 502 @{ error = $apiError }
        continue
      }
      $mia = Convert-Mia $response
      Write-Json $context 200 $mia
      continue
    }

    $rel = "index.html"
    if ($path -ne "/" -and $path -ne "/index.html") { $rel = "" }
    $file = Join-Path $root "index.html"
    if ($rel -and (Test-Path -LiteralPath $file)) {
      $bytes = [IO.File]::ReadAllBytes($file)
      $context.Response.StatusCode = 200
      $context.Response.ContentType = "text/html; charset=utf-8"
      $context.Response.ContentLength64 = $bytes.Length
      $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $context.Response.StatusCode = 404
    }
    $context.Response.OutputStream.Close()
  } catch {
    try { Write-Json $context 500 @{ error = "server_error" } } catch { }
  }
}
