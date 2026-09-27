<#
  upload-deck.ps1
  ----------------------------------------------------------------------
  يرفع ملف الـ pptx من جهازك إلى مستودع MOH-FLOW على الفرع المخصّص،
  حتى أستطيع قراءته كاملاً في الجلسة.

  لماذا سكربت ولماذا لا نسحب الملف في المتصفح؟
    واجهة GitHub على الويب تقبل 25MB فقط للملف الواحد. الرفع عبر git
    يقبل حتى 100MB، وملفك أكبر من 30MB.

  المتطلبات: Git for Windows مُثبَّت  (https://git-scm.com/download/win)
             سيطلب منك تسجيل الدخول إلى GitHub في المتصفح أول مرة.

  الاستخدام:
      powershell -ExecutionPolicy Bypass -File .\upload-deck.ps1 -Pptx "F:\...\DESIGN\اسم الملف.pptx"
  ----------------------------------------------------------------------
#>
[CmdletBinding()]
param(
    # مسار ملف الـ pptx على جهازك
    [Parameter(Mandatory = $true)]
    [string] $Pptx,

    # الفرع المخصّص لهذه المهمة — لا تغيّره إلا بطلب
    [string] $Branch = 'claude/clothing-factories-pptx-h6tdsj',

    [string] $RepoUrl = 'https://github.com/MOH-AI-61/MOH-FLOW.git'
)

$ErrorActionPreference = 'Stop'

# ---------- التحقق ----------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git غير مُثبَّت. نزّله من https://git-scm.com/download/win ثم أعد المحاولة."
}

$src = (Resolve-Path -LiteralPath $Pptx).ProviderPath
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
    throw "لم أجد الملف: $src"
}

$sizeMB = [math]::Round((Get-Item -LiteralPath $src).Length / 1MB, 2)
if ($sizeMB -ge 100) {
    throw "الحجم $sizeMB MB يتجاوز حد GitHub (100MB). صغّره أولاً بـ shrink-pptx.ps1."
}
if ($sizeMB -ge 50) {
    Write-Warning "الحجم $sizeMB MB — سيقبله GitHub لكن مع تحذير (الحد الناعم 50MB)."
}

Write-Host ""
Write-Host "الملف : $src"
Write-Host "الحجم : $sizeMB MB"
Write-Host "الفرع : $Branch"
Write-Host ""

# ---------- استنساخ المستودع في مجلد مؤقت ----------
$work = Join-Path $env:TEMP ("moh-flow-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))

try {
    Write-Host "1/4  استنساخ المستودع..."
    git clone --quiet $RepoUrl $work
    if ($LASTEXITCODE -ne 0) { throw "فشل الاستنساخ. تحقّق من الاتصال وصلاحية حسابك على GitHub." }

    Push-Location $work
    try {
        # الفرع قد يكون موجوداً على origin أو لا
        git rev-parse --verify --quiet "origin/$Branch" | Out-Null
        if ($LASTEXITCODE -eq 0) {
            git checkout --quiet -B $Branch "origin/$Branch"
        } else {
            git checkout --quiet -B $Branch
        }

        Write-Host "2/4  نسخ الملف..."
        $destDir = Join-Path $work 'deck'
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $destDir -Force

        Write-Host "3/4  إنشاء الكوميت..."
        git add --all
        git -c user.name="MOH" -c user.email="moh.arch.design@gmail.com" `
            commit --quiet -m "deck: add sportswear design presentation for factory sourcing"
        if ($LASTEXITCODE -ne 0) { throw "لا شيء للكوميت — هل الملف مرفوع مسبقاً؟" }

        Write-Host "4/4  الرفع إلى GitHub (قد يطلب تسجيل الدخول)..."
        $pushed = $false
        $delays = @(2, 4, 8, 16)
        for ($i = 0; $i -lt 5; $i++) {
            git push -u origin $Branch
            if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
            if ($i -lt 4) {
                Write-Warning "فشل الرفع — إعادة المحاولة بعد $($delays[$i]) ثانية..."
                Start-Sleep -Seconds $delays[$i]
            }
        }
        if (-not $pushed) { throw "فشل الرفع بعد عدّة محاولات." }

        Write-Host ""
        Write-Host "تمّ الرفع." -ForegroundColor Green
        Write-Host "  الملف الآن في المستودع تحت:  deck/$([IO.Path]::GetFileName($src))"
        Write-Host "  الفرع:  $Branch"
        Write-Host ""
        Write-Host "أخبرني أنك انتهيت، وسأسحبه وأقرأه كاملاً." -ForegroundColor Yellow
        Write-Host ""
    }
    finally { Pop-Location }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
