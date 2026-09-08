@echo off
chcp 65001 >nul
REM ============================================================
REM  Фарпост: разовая настройка машины с Windows под сбор цен.
REM  Запускать ДВОЙНЫМ КЛИКОМ на самой машине, под тем пользователем,
REM  который на ней обычно работает: браузеру нужен живой рабочий стол,
REM  из-под службы или ssh окно не покажется и стену пройти будет нечем.
REM ============================================================
setlocal
set WORK=C:\farpost
set RAW=https://raw.githubusercontent.com/popovalex17071985-source/dashi-plugin-claude-code/main/agent-kit/windows

echo.
echo === 1. Проверяю Node.js
where node >nul 2>&1
if errorlevel 1 (
  echo НЕТ Node.js. Поставь LTS с https://nodejs.org и запусти этот файл снова.
  pause & exit /b 1
)
node -v

echo.
echo === 2. Проверяю Google Chrome
if not exist "C:\Program Files\Google\Chrome\Application\chrome.exe" (
  echo НЕТ Chrome. Поставь обычный Google Chrome и запусти этот файл снова.
  pause & exit /b 1
)
echo Chrome на месте

echo.
echo === 3. Рабочая папка %WORK%
if not exist "%WORK%" mkdir "%WORK%"
cd /d "%WORK%"

echo.
echo === 4. Ставлю библиотеку браузера (patchright)
if not exist package.json call npm init -y >nul
call npm install patchright@1.62.2 --no-fund --no-audit
if errorlevel 1 (
  echo Не встала библиотека. Проверь интернет и права, запусти снова.
  pause & exit /b 1
)

echo.
echo === 5. Качаю скрипты сбора
for %%F in (fp-scrape.js fp-probe.js fp-hold.js) do (
  curl -fsSL "%RAW%/%%F" -o "%WORK%\%%F"
  if errorlevel 1 (echo Не скачался %%F & pause & exit /b 1)
)
dir /b fp-*.js

echo.
echo === 6. Проверка стены Фарпоста
node fp-probe.js 0
echo.
echo Если выше написано, что стена стоит -- запусти:  node fp-hold.js
echo Откроется окно, поставь галку "я не робот", и оно закроется само.
echo Кука живёт около года, больше это не понадобится.
echo.
echo === Готово. Сбор магазина запускается так:
echo    cd /d %WORK% ^&^& node fp-scrape.js AppleDubaiVL
echo Результат ляжет в %WORK%\farpost-AppleDubaiVL.json
echo.
pause
