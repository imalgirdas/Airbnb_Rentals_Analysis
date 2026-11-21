@echo off
rem =====================================================================
rem 06_export_clean_data.bat  -  export airbnb_clean to CSV for Looker Studio
rem =====================================================================
rem Sits in the same folder as 06_export_clean_data.sql. Double-click, or from cmd:
rem
rem     cd C:\Users\algir\Desktop\Projects\SQL\MySQL\Airbnb
rem     06_export_clean_data.bat
rem
rem Steps:
rem   1. asks for the MySQL root password once
rem   2. runs 06_export_clean_data.sql (rpt_ views + sp_export_csv)
rem   3. writes the 4 dashboard files to   Clean_data\
rem      and every clean table to          Clean_data\tables\
rem
rem Output: UTF-8, comma separated, header row, dates as YYYY-MM-DD, NULL = empty cell.
rem Excel garbles accents on double-click (Looker is fine). To check a file in Excel
rem use Data > From Text/CSV with UTF-8.
rem =====================================================================

setlocal
set "MYSQL=C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"
set "HERE=%~dp0"
set "OUT=%HERE%Clean_data"
set "CNF=%TEMP%\airbnb_export_%RANDOM%.cnf"

if not exist "%MYSQL%" (
  echo mysql.exe not found at "%MYSQL%". Edit the MYSQL line at the top of this file.
  goto :fail
)

rem --- password goes into a temp option file (no mysql warning per table),
rem --- deleted again at the end
set /p "PW=MySQL root password: "
> "%CNF%" (
  echo [client]
  echo user=root
  echo password="%PW%"
  echo default-character-set=utf8mb4
)
set "PW="

if not exist "%OUT%"        mkdir "%OUT%"
if not exist "%OUT%\tables" mkdir "%OUT%\tables"

echo.
echo Creating report views ...
"%MYSQL%" --defaults-extra-file="%CNF%" < "%HERE%06_export_clean_data.sql"
if errorlevel 1 goto :fail

echo.
echo Dashboard files (Clean_data):
for %%T in (rpt_bookings rpt_listings rpt_city_month rpt_reviews) do (
  echo   %%T.csv
  "%MYSQL%" --defaults-extra-file="%CNF%" -N -B --raw -e "CALL airbnb_clean.sp_export_csv('%%T')" > "%OUT%\%%T.csv"
  if errorlevel 1 goto :fail
)

echo.
echo Clean tables (Clean_data\tables):
for %%T in (countries cities neighbourhoods hosts guests amenities listings listing_amenities bookings payments reviews fx_rates) do (
  echo   %%T.csv
  "%MYSQL%" --defaults-extra-file="%CNF%" -N -B --raw -e "CALL airbnb_clean.sp_export_csv('%%T')" > "%OUT%\tables\%%T.csv"
  if errorlevel 1 goto :fail
)

del "%CNF%" >nul 2>&1
echo.
echo Done. Files are in "%OUT%"
pause
exit /b 0

:fail
del "%CNF%" >nul 2>&1
echo.
echo *** Export stopped because of the error above. ***
echo     Wrong password? Did 02 and 03 run first, so airbnb_clean has data?
pause
exit /b 1
