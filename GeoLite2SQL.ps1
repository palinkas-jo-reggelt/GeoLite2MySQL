<#

.SYNOPSIS
	Install MaxMinds geoip database to database server

.DESCRIPTION
	Downloads and unzips MaxMinds csv geoip data, then populate table on database server with csv data

.FUNCTIONALITY
	1) If geoip table does not exist, it gets created
	2) Deletes old files if existing
	3) Downloads MaxMinds geolite2 cvs data as zip file, uncompresses it, then renames the folder
	4) Compares new (csv) and old (database) data for changes
	5) Reads IPv4 cvs data, then calculates the lowest and highest IP from each network in the database
	6) Deletes obsolete records
	7) Inserts lowest and highest IP in range and geoname_id from IPv4 cvs file
	8) Reads geo-name cvs file and updates each record with country code and country name based on the geoname_id
	9) Includes various error checking
	10) Feedback on console and by email on weekly updates.

.NOTES
	Run every Wednesday via task scheduler (MaxMinds releases updates on Tuesdays)
	
.EXAMPLE
	Example query to return countrycode and countryname from database:
	
		MySQL:
	
			SELECT countrycode, countryname FROM (SELECT * FROM geo_ip WHERE INET_ATON('125.64.94.220') <= maxipaton LIMIT 1) AS A WHERE minipaton <= INET_ATON('125.64.94.220')
	
		MSSQL:
	
			SELECT countrycode, countryname FROM (SELECT * FROM geo_ip WHERE dbo.ipStringToInt('125.64.94.220') <= maxipaton LIMIT 1) AS A WHERE minipaton <= dbo.ipStringToInt('125.64.94.220')

#>

<#  Include required files  #>
Try {
	.("$PSScriptRoot\Config.ps1")
	.("$PSScriptRoot\CommonCode.ps1")
}
Catch {
	Write-Output "$((get-date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to load supporting PowerShell Scripts : $query `n$Error[0]" | out-file "$PSScriptRoot\PSError.log" -append
}

<############################
#
#       BEGIN SCRIPT
#
############################>

<#  Clear out any errors  #>
$error.clear()

<#  Set file locations  #>
$MMcsv = "$PSScriptRoot\Script-Created-Files\CSV-MM.csv"
$DBcsv = "$PSScriptRoot\Script-Created-Files\CSV-DB.csv"
$ToAddIPv4 = "$PSScriptRoot\Script-Created-Files\ToAddIPv4.csv"
$ToDelIPv4 = "$PSScriptRoot\Script-Created-Files\ToDelIPv4.csv"
$CountryBlocksIPV4 = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLite2-Country-Blocks-IPv4.csv"
$CountryLocations = "$PSScriptRoot\GeoLite2-Country-CSV\GeoLite2-Country-Locations-$CountryLocationLang.csv"
$EmailBody = "$PSScriptRoot\Script-Created-Files\EmailBody.txt"
$DebugLog = "$PSScriptRoot\DebugLog.log"

<#	Delete old debug log before debugging  #>
If (Test-Path $DebugLog) {Remove-Item -Force -Path $DebugLog}
New-Item $DebugLog

<#  Set start time  #>
$StartScriptTime = (Get-Date -f G)
VerboseOutput "`n$(Get-Date -f G) : GeoIP Update Start Script"
EmailOutput "`n$(Get-Date -f G) : GeoIP Update Start Script"

<#	Create folder for temporary script files if it doesn't exist  #>
VerboseOutput "$(Get-Date -f G) : Create folder for temporary files"
If (-not(Test-Path "$PSScriptRoot\Script-Created-Files")) {
	md "$PSScriptRoot\Script-Created-Files"
}

<#	Delete old files if exist  #>
VerboseOutput "$(Get-Date -f G) : Deleting old files"
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV") {Remove-Item -Recurse -Force "$PSScriptRoot\GeoLite2-Country-CSV"}
If (Test-Path "$PSScriptRoot\Script-Created-Files\GeoLite2-Country-CSV.zip") {Remove-Item -Force -Path "$PSScriptRoot\Script-Created-Files\GeoLite2-Country-CSV.zip"}
If (Test-Path $EmailBody) {Remove-Item -Force -Path $EmailBody}
If (Test-Path $MMcsv) {Remove-Item -Force -Path $MMcsv}
If (Test-Path $DBcsv) {Remove-Item -Force -Path $DBcsv}
If (Test-Path $ToAddIPv4) {Remove-Item -Force -Path $ToAddIPv4}
If (Test-Path $ToDelIPv4) {Remove-Item -Force -Path $ToDelIPv4}

<#	Check to make sure files deleted  #>
If ((Test-Path $ToAddIPv4) -or (Test-Path $ToDelIPv4)){
	VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Failed to delete old ToDelIPv4.csv and/or ToAddIPv4.csv"
	VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
	EmailOutput "GeoIP update failed to delete old files. See error log."
	If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
		EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
	}
	EmailResults
	Exit
}

<#	Download latest GeoLite2 data and unzip  #>
VerboseOutput "$(Get-Date -f G) : Downloading MaxMind data"
Try {
	$url = "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country-CSV&license_key=$LicenseKey&suffix=zip"
	$output = "$PSScriptRoot\Script-Created-Files\GeoLite2-Country-CSV.zip"
	Start-BitsTransfer -Source $url -Destination $output -ErrorAction Stop
	Expand-Archive $output -DestinationPath $PSScriptRoot -ErrorAction Stop
}
Catch {
	VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to download and/or unzip : `n$Error[0]"
	VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
	EmailOutput "GeoIP update failed to download or unzip maxminds data zip file. See error log  : `n$Error[0]"
	If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
		EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
	}
	EmailResults
	Exit
}

<#	Rename folder so script can find it  #>
VerboseOutput "$(Get-Date -f G) : Renaming MaxMind data folder"
Get-ChildItem $PSScriptRoot | Where-Object {$_.PSIsContainer -eq $true} | ForEach {
	If ($_.Name -match 'GeoLite2-Country-CSV_[0-9]{8}') {
		$FolderName = $_.Name
		Rename-Item "$PSScriptRoot\$FolderName" "$PSScriptRoot\GeoLite2-Country-CSV"
	}
}

<# 	If new downloaded folder does not exist or could not be renamed, then throw error  #>
If (-not (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV")){
	VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : $PSScriptRoot\GeoLite2-Country-CSV does not exist"
	VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
	EmailOutput "GeoIP update failed at folder rename. See error log."
	If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
		EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
	}
	EmailResults
	Exit
}

<#	Count existing database records for error checking later  #>
$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
RunSQLQuery($Query) | ForEach {
	$EntryCount = $_.numrows
}
VerboseOutput "$(Get-Date -f G) : Querying number of records in database before starting : $EntryCount records"

<############################
#
#     DATABASE UPDATE
#
############################>

<#  If new MaxMind download exists, proceed to load database  #>
If (Test-Path "$PSScriptRoot\GeoLite2-Country-CSV"){

	<#  Dump relevant MaxMind data into comparison csv  #>
	VerboseOutput "$(Get-Date -f G) : Loading MaxMind CountryBlocks csv"
	$MMMakeComparisonCSV = Import-CSV -Path $CountryBlocksIPV4 -Delimiter "," -Header network,geoname_id,registered_country_geoname_id,represented_country_geoname_id,is_anonymous_proxy,is_satellite_provider
	VerboseOutput "$(Get-Date -f G) : MaxMind CSV Loaded"
	VerboseOutput "$(Get-Date -f G) : Exporting MaxMind data to reduced csv for comparison"
	$MMMakeComparisonCSV | Select-Object -Property network,@{Name = 'geoname_id'; Expression = {If([string]::IsNullOrWhiteSpace($_.geoname_id)){$_.registered_country_geoname_id} Else {$_.geoname_id}}} | Export-CSV -Path $MMcsv
	VerboseOutput "$(Get-Date -f G) : Reduced csv exported"

	[int]$LinesNewCSV = $MMMakeComparisonCSV.Count - 1
	VerboseOutput "$(Get-Date -f G) : $LinesNewCSV Records in MaxMind CountryBlocks csv"
	
	VerboseOutput "$(Get-Date -f G) : Loading entries from database for comparison to MaxMind data"
	<#  Dump relevant database data into comparison csv  #>
	$Query = "SELECT network, geoname_id FROM $GeoIPTable"
	RunSQLQuery($Query) | Export-CSV -Path $DBcsv
	VerboseOutput "$(Get-Date -f G) : Database entries Loaded"

	<#  Compare database and MaxMind data for changes  #>

	If ((Test-Path $MMcsv) -and (Test-Path $DBcsv)){
		VerboseOutput "$(Get-Date -f G) : Comparing updated MaxMind data to database"
		Compare-Object -ReferenceObject $(Get-Content $DBcsv) -DifferenceObject $(Get-Content $MMcsv) | ForEach-Object {
			If ($_.SideIndicator -eq '=>') {
				Write-Output $_.InputObject | Out-File $ToAddIPv4 -Encoding ASCII -Append
			} Else {
				Write-Output $_.InputObject | Out-File $ToDelIPv4 -Encoding ASCII -Append
			}
		}
		VerboseOutput "$(Get-Date -f G) : Comparison completed"
	}

	Try {
		
		$RegexNetwork = '((?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)(\/([0-9]|[0-2][0-9]|3[0-2])))'
		
		<#  Read ToDelIPv4 csv file, delete matches from database  #>
		VerboseOutput "$(Get-Date -f G) : Preparing to delete MaxMind removed records from database"
		$GeoIPObjects = Import-CSV -Path $ToDelIPv4 -Delimiter "," -Header network,geoname_id
		VerboseOutput "$(Get-Date -f G) : Csv loaded, ready to delete records from database"
		
		$TotalLines = ($GeoIPObjects | Measure-Object).Count
		$LinesToDel = $TotalLines
		$LineCounter = 0
		$StartTime = (Get-Date -f G)

		$GeoIPObjects | ForEach-Object {

			<#  Progress Counter  #>
			If ($VerboseConsole){
				$LineCounter++
			
				$CurrentTime = (Get-Date -f G)
				$OperationTime = New-Timespan $StartTime $CurrentTime
				$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
				$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
				$Percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
				Write-Progress -Activity "Processing lines - Deleting old networks" -Status "Record $LineCounter of $TotalLines : $Percent% Complete" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;
			}
			
			$Network = $_.network
			$GeoNameID = $_.geoname_id
			If ($Network -match $RegexNetwork){
				$MaxIP = (Get-IPv4NetworkInfo -CIDRAddress $Network).BroadcastAddress
				$Query = "DELETE FROM $GeoIPTable WHERE maxipaton = $(DBIpStringToIntField $MaxIP)"
				RunSQLQuery($Query)
			}
		}
		VerboseOutput "$(Get-Date -f G) : Finished deleting records from database"

	}
	Catch {
		VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Update failed : `n$Error[0]"
		VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
		EmailOutput "GeoIP update failed at deleting old network records from database. See debug log for error."
		If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
			EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
		}
		EmailResults
		Exit
	}

	Try {
		<#  Read ToAddIPv4 csv file, convert CIDR network address to lowest and highest IPs in range, then insert into database  #>
		VerboseOutput "$(Get-Date -f G) : Preparing to add new records to database from comparison csv"
		$GeoIPObjects = Import-CSV -Path $ToAddIPv4 -Delimiter "," -Header network,geoname_id
		VerboseOutput "$(Get-Date -f G) : Csv loaded, ready to add updated records to database"

		$TotalLines = ($GeoIPObjects | Measure-Object).Count
		$LinesToAdd = $TotalLines - 1
		$LineCounter = 0
		$StartTime = (Get-Date -f G)
		
		$GeoIPObjects | ForEach-Object {

			If ($VerboseConsole){
				$LineCounter++
			
				$CurrentTime = (Get-Date -f G)
				$OperationTime = New-Timespan $StartTime $CurrentTime
				$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
				$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
				$Percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
				Write-Progress -Activity "Processing lines - Inserting new networks" -Status "Record $LineCounter of $TotalLines : $Percent% Complete" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;
			}
			
			$Network = $_.network
			$GeoNameID = $_.geoname_id
			If ($Network -match $RegexNetwork){
				Get-IPv4NetworkInfo -CIDRAddress $Network | ForEach-Object {
					$MinIP = $_.NetworkAddress
					$MaxIP = $_.BroadcastAddress
				}

				<#  If geoname_id is blank, get the country code from ip-api.com and cross reference geoname_id with MaxMind country name csv  #>
				If ([string]::IsNullOrEmpty($GeoNameID)){
					$MissingCountry = Invoke-RestMethod http://ip-api.com/json/$MinIP | Select -exp countryCode
					$MissingGeoID = Import-CSV -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
					$Selection = $MissingGeoID | Where-Object {($_.country_iso_code -eq $MissingCountry)}
					$GeoNameID = $Selection.geoname_id
				}
				$Query = "INSERT INTO $GeoIPTable (network,minip,maxip,geoname_id,minipaton,maxipaton,countrycode,countryname) VALUES ('$Network','$MinIP','$MaxIP','$GeoNameID',$(DBIpStringToIntField $MinIP), $(DBIpStringToIntField $MaxIP),'','')"
				RunSQLQuery $Query
			}
		}
		VerboseOutput "$(Get-Date -f G) : Finished adding updated records to database"

	}
	Catch {
		VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Update failed : `n$Error[0]"
		VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
		EmailOutput "GeoIP update failed at loading new network records into database. See debug log for error."
		If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
			EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
		}
		EmailResults
		Exit
	}

	Try {
		<# 	Read country info csv and insert into database  #>
		VerboseOutput "$(Get-Date -f G) : Loading updated MaxMind country name CSV"
		$GeoIPNameObjects = Import-CSV -Path $CountryLocations -Delimiter "," -Header geoname_id,locale_code,continent_code,continent_name,country_iso_code,country_name,is_in_european_union
		VerboseOutput "$(Get-Date -f G) : Country name csv loaded, ready to update records in database"

		$TotalLines = ($GeoIPNameObjects | Measure-Object).Count
		$LineCounter = 0
		$StartTime = (Get-Date -f G)

		$GeoIPNameObjects | ForEach-Object {

			If ($VerboseConsole){
				$LineCounter++
			
				$CurrentTime = (Get-Date -f G)
				$OperationTime = New-Timespan $StartTime $CurrentTime
				$SecondsPassed = $OperationTime.TotalSeconds / $LineCounter
				$SecondsRemaining = ($TotalLines - $LineCounter) * $SecondsPassed
				$Percent = [math]::Round(($LineCounter * 100) / $TotalLines,2)
				Write-Progress -Activity "Processing lines - Inserting country names" -Status "Record $LineCounter of $TotalLines : $Percent% Complete" -PercentComplete $percent -SecondsRemaining $SecondsRemaining;
			}
			
			$GeoNameID = $_.geoname_id
			$CountryCode = $_.country_iso_code
			$CountryName = $_.country_name
			If ($GeoNameID -notmatch 'geoname_id'){
				$Query = "UPDATE $GeoIPTable SET countrycode='$CountryCode', countryname='$CountryName' WHERE geoname_id='$GeoNameID' AND countrycode='' AND countryname=''"
				RunSQLQuery($Query)
			}
		}
		VerboseOutput "$(Get-Date -f G) : Finished updating country name records in database"
		
	}
	Catch {
		VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Update failed : `n$Error[0]"
		VerboseOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
		EmailOutput "GeoIP update failed at loading country name data into database. See debug log for error."
		If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
			EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
		}
		EmailResults
		Exit
	}

	<#  Count records in database (post-update)  #>
	$Query = "SELECT COUNT(minip) AS numrows FROM $GeoIPTable"
	RunSQLQuery($Query) | ForEach {
		$DBCountAfterIncrUpdate = $_.numrows
	}

	[int]$SumOldDelAdd = ($EntryCount - $LinesToDel + $LinesToAdd)

	<#  Report Results  #>
	VerboseOutput "$(Get-Date -f G) : Database update complete - preparing email report."
	VerboseOutput " "
	VerboseOutput ("{0,7} : (A) Records in database prior to update" -f ($EntryCount).ToString("#,###"))
	VerboseOutput ("{0,7} : (B) Records tabulated to be removed from database" -f ($LinesToDel).ToString("#,###"))
	VerboseOutput ("{0,7} : (C) Records tabulated to be inserted into database" -f ($LinesToAdd).ToString("#,###"))
	VerboseOutput "======= :"
	VerboseOutput ("{0,7} : Tabulated (A - B + C) number of records (should match NEW IPV4 csv)" -f ($SumOldDelAdd).ToString("#,###"))
	VerboseOutput "======= :"
	VerboseOutput ("{0,7} : Actual number of records in NEW IPV4 csv" -f ($LinesNewCSV).ToString("#,###"))
	VerboseOutput "======= :"
	VerboseOutput ("{0,7} : Queried number of records in database (should match NEW IPV4 csv)" -f ($DBCountAfterIncrUpdate).ToString("#,###"))
	VerboseOutput " "

	EmailOutput   " "
	EmailOutput   ("{0,7} : (A) Records in database prior to update" -f ($EntryCount).ToString("#,###"))
	EmailOutput   ("{0,7} : (B) Records tabulated to be removed from database" -f ($LinesToDel).ToString("#,###"))
	EmailOutput   ("{0,7} : (C) Records tabulated to be inserted into database" -f ($LinesToAdd).ToString("#,###"))
	EmailOutput   "======= :"
	EmailOutput   ("{0,7} : Tabulated (A - B + C) number of records (should match NEW IPV4 csv)" -f ($SumOldDelAdd).ToString("#,###"))
	EmailOutput   "======= :"
	EmailOutput   ("{0,7} : Actual number of records in NEW IPV4 csv" -f ($LinesNewCSV).ToString("#,###"))
	EmailOutput   "======= :"
	EmailOutput   ("{0,7} : Queried number of records in database (should match NEW IPV4 csv)" -f ($DBCountAfterIncrUpdate).ToString("#,###"))
	EmailOutput   " "

	<#  Determine success or failure  #>
	If (($SumOldDelAdd -ne $LinesNewCSV) -or ($DBCountAfterIncrUpdate -ne $LinesNewCSV)) {
		EmailOutput "GeoIP database update ***FAILED**. Record Count Mismatch"
		VerboseOutput "GeoIP database update ***FAILED**. Record Count Mismatch"
	} Else {
		EmailOutput "GeoIP database update SUCCESS. All records accounted for."
		VerboseOutput "GeoIP database update SUCCESS. All records accounted for."
	}
	VerboseOutput "$(Get-Date -f G) : Preparing email report."
}

<#########################################
#
#  NO DATABASE LOADING (ERROR)
#
#########################################>

<#  Else Exit since database load can be accomplished  #>
Else {
	EmailOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Unable to complete database load : MaxMind data doesn't exist."
	EmailOutput "$((Get-Date).ToString(`"yy/MM/dd HH:mm:ss.ff`")) : ERROR : Quitting Script"
	EmailOutput "GeoIP update failed: MaxMind data doesn't exist. See error log."
	If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
		EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
	}
	EmailResults
	Exit
}

<#########################################
#
#  FINISH UP
#
#########################################>

<#  Now finish up with email results  #>
EmailOutput " "
EmailOutput " "
EmailOutput "GeoIP update completed."
EmailOutput " "

$EndTime = (Get-Date -f G)
VerboseOutput "GeoIP update finish: $EndTime"
EmailOutput "GeoIP update finish: $EndTime"
$OperationTime = New-Timespan $StartScriptTime $EndTime
If (($OperationTime).Hours -eq 1) {$sh = ""} Else {$sh = "s"}
If (($OperationTime).Minutes -eq 1) {$sm = ""} Else {$sm = "s"}
If (($OperationTime).Seconds -eq 1) {$ss = ""} Else {$ss = "s"}
EmailOutput " "
EmailOutput ("Completed update in {0:%h} hour$sh {0:%m} minute$sm {0:%s} second$ss" -f $OperationTime)
VerboseOutput ("Completed update in {0:%h} hour$sh {0:%m} minute$sm {0:%s} second$ss" -f $OperationTime)

If (($AttachDebugLog) -and (((Get-Item $DebugLog).length/1MB) -gt $MaxAttachmentSize)){
	EmailOutput "Debug log too large to email. Please see file in GeoLite2SQL script folder."
}

EmailResults