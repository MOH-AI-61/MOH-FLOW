<#
  shrink-pptx.ps1
  ----------------------------------------------------------------------
  يصغّر حجم ملف PowerPoint (.pptx) عن طريق تصغير أبعاد وجودة الصور
  الموجودة داخله، بدون الحاجة لفتح PowerPoint نفسه.
  الملف الأصلي لا يُلمس — يُنتَج ملف جديد بالاسم نفسه + "_small".

  طريقة الاستخدام (من PowerShell على ويندوز):
      powershell -ExecutionPolicy Bypass -File .\shrink-pptx.ps1 -Path "F:\المسار\الملف.pptx"

  للتصغير أكثر (لو ما زال الحجم كبيراً):
      ... -Path "..." -MaxDimension 1200 -JpegQuality 60
  ----------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    # مسار ملف الـ pptx الأصلي
    [Parameter(Mandatory = $true)]
    [string] $Path,

    # مسار الملف الناتج (اختياري)
    [string] $OutPath,

    # أقصى بعد للصورة بالبكسل (العرض أو الطول، أيّهما أكبر)
    [int] $MaxDimension = 1600,

    # جودة ضغط JPEG من 1 إلى 100
    [ValidateRange(1, 100)]
    [int] $JpegQuality = 72
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------- التحقق من المدخلات ----------
$src = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
    throw "لم أجد الملف: $src"
}
if ([IO.Path]::GetExtension($src) -notin @('.pptx', '.potx', '.ppsx')) {
    throw "الملف ليس pptx/potx/ppsx: $src"
}

if (-not $OutPath) {
    $dir  = [IO.Path]::GetDirectoryName($src)
    $base = [IO.Path]::GetFileNameWithoutExtension($src)
    $ext  = [IO.Path]::GetExtension($src)
    $OutPath = Join-Path $dir "${base}_small${ext}"
}

$sizeBefore = (Get-Item -LiteralPath $src).Length

Write-Host ""
Write-Host "المصدر : $src"
Write-Host "الحجم  : $([math]::Round($sizeBefore/1MB, 2)) MB"
Write-Host "الناتج : $OutPath"
Write-Host "الإعداد: أقصى بعد = $MaxDimension بكسل، جودة JPEG = $JpegQuality"
Write-Host ""

# ---------- مجلد عمل مؤقت ----------
$work = Join-Path $env:TEMP ("pptx_shrink_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

try {
    # ---------- فك الضغط (ملف pptx هو في الأصل ملف zip) ----------
    Write-Host "1/3  فكّ الضغط..."
    [IO.Compression.ZipFile]::ExtractToDirectory($src, $work)

    # ---------- تصغير الصور ----------
    Write-Host "2/3  معالجة الصور..."

    $jpegCodec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                 Where-Object { $_.MimeType -eq 'image/jpeg' }
    $encParams = New-Object Drawing.Imaging.EncoderParameters 1
    $encParams.Param[0] = New-Object Drawing.Imaging.EncoderParameter(
                              [Drawing.Imaging.Encoder]::Quality, [long]$JpegQuality)

    $mediaDirs = Get-ChildItem -LiteralPath $work -Directory -Recurse -Filter 'media' -ErrorAction SilentlyContinue
    $images = @()
    foreach ($d in $mediaDirs) {
        $images += Get-ChildItem -LiteralPath $d.FullName -File |
                   Where-Object { $_.Extension -in @('.jpg', '.jpeg', '.png') }
    }

    $touched = 0
    $savedBytes = 0

    foreach ($img in $images) {
        $file  = $img.FullName
        $isJpg = $img.Extension -in @('.jpg', '.jpeg')
        $before = $img.Length

        try {
            # نقرأ البايتات إلى الذاكرة حتى لا يبقى الملف مقفولاً
            $bytes  = [IO.File]::ReadAllBytes($file)
            $stream = New-Object IO.MemoryStream($bytes, $false)
            $bmpSrc = [Drawing.Image]::FromStream($stream)

            $w = $bmpSrc.Width
            $h = $bmpSrc.Height
            $maxSide = [Math]::Max($w, $h)

            # نعيد الحفظ فقط إذا كانت الصورة أكبر من الحد، أو JPEG كبيرة الحجم
            $needsResize  = $maxSide -gt $MaxDimension
            $needsRequant = $isJpg -and ($before -gt 300KB)

            if (-not ($needsResize -or $needsRequant)) {
                $bmpSrc.Dispose(); $stream.Dispose()
                continue
            }

            if ($needsResize) {
                $ratio = $MaxDimension / $maxSide
                $nw = [Math]::Max(1, [int]($w * $ratio))
                $nh = [Math]::Max(1, [int]($h * $ratio))
            } else {
                $nw = $w; $nh = $h
            }

            $canvas = New-Object Drawing.Bitmap($nw, $nh,
                          [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [Drawing.Graphics]::FromImage($canvas)
            $g.InterpolationMode  = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode    = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode      = [Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.DrawImage($bmpSrc, 0, 0, $nw, $nh)
            $g.Dispose()

            $bmpSrc.Dispose()
            $stream.Dispose()

            # نحفظ بنفس الصيغة الأصلية — تغيير الصيغة قد يُفسد الملف
            $tmp = "$file.tmp"
            if ($isJpg) {
                $canvas.Save($tmp, $jpegCodec, $encParams)
            } else {
                $canvas.Save($tmp, [Drawing.Imaging.ImageFormat]::Png)
            }
            $canvas.Dispose()

            $after = (Get-Item -LiteralPath $tmp).Length
            if ($after -lt $before) {
                Move-Item -LiteralPath $tmp -Destination $file -Force
                $touched++
                $savedBytes += ($before - $after)
            } else {
                # الناتج أكبر — نُبقي الأصل
                Remove-Item -LiteralPath $tmp -Force
            }
        }
        catch {
            Write-Warning "     تجاوزت: $($img.Name)  ($($_.Exception.Message))"
            if (Test-Path -LiteralPath "$file.tmp") { Remove-Item -LiteralPath "$file.tmp" -Force }
        }
    }

    Write-Host "     صور مُعالَجة: $touched من $($images.Count)  —  وفّرنا $([math]::Round($savedBytes/1MB,2)) MB"

    # ---------- إعادة الضغط ----------
    Write-Host "3/3  إعادة بناء الملف..."
    if (Test-Path -LiteralPath $OutPath) { Remove-Item -LiteralPath $OutPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $work, $OutPath, [IO.Compression.CompressionLevel]::Optimal, $false)

    $sizeAfter = (Get-Item -LiteralPath $OutPath).Length
    $pct = [math]::Round(100 - ($sizeAfter / $sizeBefore * 100), 1)

    Write-Host ""
    Write-Host "تمّ." -ForegroundColor Green
    Write-Host "  قبل : $([math]::Round($sizeBefore/1MB,2)) MB"
    Write-Host "  بعد : $([math]::Round($sizeAfter/1MB,2)) MB   (انخفاض $pct%)"
    Write-Host "  الملف: $OutPath"
    Write-Host ""
    Write-Host "افتح الملف الناتج في PowerPoint للتأكد أن الصور سليمة قبل إرساله." -ForegroundColor Yellow
    Write-Host ""
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
