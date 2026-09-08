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
echo === 7. Канал до сервера агента
echo Агент живёт на сервере и сам сюда не достучится: у машины нет белого адреса.
echo Поэтому машина сама держит обратный туннель до сервера.
echo.
set /p SRV=Адрес сервера агента (например user@1.2.3.4), пусто = пропустить: 
if "%SRV%"=="" goto :skiptunnel

echo.
echo --- 7.1 Включаю приём подключений (OpenSSH Server)
powershell -NoProfile -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0" >nul 2>&1
powershell -NoProfile -Command "Set-Service sshd -StartupType Automatic; Start-Service sshd"
powershell -NoProfile -Command "(Get-Service sshd).Status"

echo.
echo --- 7.2 Ключ для выхода на сервер
if not exist "%WORK%	unnel-key" ssh-keygen -t ed25519 -N "" -f "%WORK%	unnel-key" -C "farpost-tunnel"
echo.
echo ВОТ ЭТУ СТРОКУ отдай агенту -- он добавит её себе на сервер:
echo ------------------------------------------------------------
type "%WORK%	unnel-key.pub"
echo ------------------------------------------------------------
echo.
echo Когда агент скажет, что добавил -- нажми любую клавишу.
pause >nul

echo.
echo --- 7.3 Задача, которая держит туннель постоянно
schtasks /create /tn farpost-tunnel /f /sc onstart /ru "%USERNAME%" /rl highest ^
  /tr "\"C:\Windows\System32\OpenSSH\ssh.exe\" -N -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o BatchMode=yes -i \"%WORK%\tunnel-key\" -R 2224:localhost:22 %SRV%"
schtasks /run /tn farpost-tunnel
echo Туннель запущен. Порт на сервере: 2224
echo Агент проверяет так:  ssh -p 2224 %USERNAME%@127.0.0.1 "cd /d C:\farpost && node fp-probe.js 0"

:skiptunnel

echo.
echo === Готово. Сбор магазина запускается так:
echo    cd /d %WORK% ^&^& node fp-scrape.js AppleDubaiVL
echo Результат ляжет в %WORK%\farpost-AppleDubaiVL.json
echo.
pause
