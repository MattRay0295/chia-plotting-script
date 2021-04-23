#!/bin/zsh
#bail if the user is root, this is too dangerous, comment this out at your own risk. 
if [[ $EUID -eq 0 ]]; then
  echo "This script must NOT be run as root, SET UP PROPER PERMISSIONS!!!!" 1>&2
  exit 1
fi

#ssh settings
user="luna"
server="192.168.0.192"

#global defaults
LOG_DIR="./logs"
PLOT_FINAL_SIZE=$((109000000000/1024))
PLOT_FOLDERS=("/chiaTempStor/" "/chiaTempStor2/" "/chiaTempStor3/")
REMOTE_PLOT_FOLDERS=("/chia/farm1/" "/chia/farm2/" "/chia/farm3/" "/chia/farm4/" "/chia/farm5/" "/chia/farm6/" "/chia/farm7/" "/chia/farm8/" "/chia/farm9/" "/chia/farm10/" "/chia/farm11/" "/chia/farm12/" "/chia/farm13/" "/chia/farm14/" "/chia/farm15/")
MAX_PARALLEL=3
deleteSource="true"
doHash="true"
availablePlotCount="0"
declare -A folderPlotFolderCountMap
declare -A remoteFolderPlotSpaceMap

checkServerForFile()
{
	local remoteFile=$1
	local serverDirectory=$2
	if ssh "${user}"@"${server}" stat "${serverDirectory}""${remoteFile}" \> /dev/null 2\>\&1
	then
		return 0
	else
		return 1
	fi
}

copyFileToServer()
{
	local localFile=$1
	local localFolder=$2
	local serverDirectory=$3
	local logFile=$4
	local cmdSCP="scp ${localFolder}${localFile} ${user}@${server}:${serverDirectory}"
	if script -q -c "${cmdSCP}" 1>> "${logFile}"
	then
		return 0
	else
		return 1
	fi
}

getLocalHash()
{
	local localFile=$1
	local localFolder=$2
	echo `sha1sum "${localFolder}${localFile}" | awk '{print $1}'`
}

getRemoteHash()
{
	local remoteFile=$1
	local serverDirectory=$2
	local sshResult=`ssh "${user}"@"${server}" sha1sum "${serverDirectory}""${remoteFile}"`
	local awked=`echo "${sshResult}" | awk '{print $1}'`
	echo $awked
}

verifyFileWithRemote()
{
	if [[ "${doHash}" == "true" ]]
	then
		local localFile=$1
		local localFolder=$2
		local serverDirectory=$3
		local localHash=$(getLocalHash ${localFile} ${localFolder})
		local remoteHash=$(getRemoteHash ${localFile} ${serverDirectory})
		echo "Local hash: ${localHash}" 
		echo "Remote hash: ${remoteHash}" 
		if [[ "${localHash}" == "${remoteHash}" ]]
		then
			return 0
		else
			return 1
		fi
	else
		return 0
	fi
}

validateLocalFile()
{
	local localFile=$1
	local localFolder=$2
	if [ -f "${localFolder}${localFile}" ]
	then
		return 0
	else
		echo "File does not exist, failed to copy!"
		echo -e "\t${localFolder}${localFile}"
		return 1
	fi
}

copyPlot()
{
	local localFile=$1
	local localFolder=$2
	local serverDirectory=$3
	local logFile=$4
	if validateLocalFile ${localFile} ${localFolder}
	then
		if checkServerForFile ${localFile} ${serverDirectory}
		then
			if [[ "${doHash}" == "true" ]]
			then
				#file exists, lets verify its a match to the local file then delete the local file
				echo "File Exists on Server, Verifying Hashes" >> "${logFile}"
				if verifyFileWithRemote ${localFile} ${localFolder} ${serverDirectory}
				then
					if [[ "$deleteSource" == "true" ]]
					then
						echo "Files Match, removing local copy" >> "${logFile}"
						rm "${localFolder}${localFile}"
					else
						echo "Files Match, Skiping local file" >> "${logFile}"
					fi 
				else
					echo "Files do not match, overriding remote copy" >> "${logFile}"
					copyFileToServer ${localFile} ${localFolder} ${serverDirectory} ${logFile}
					echo "Copy Complete, Verifying File" >> "${logFile}"
					if verifyFileWithRemote ${localFile} ${localFolder} ${serverDirectory}
					then
						if [[ "$deleteSource" == "true" ]]
						then
							echo "Files Match, removing local copy" >> "${logFile}"
							rm "${localFolder}${localFile}"
						fi
					else
						echo "Failed to verify remote copy!!!" >> "${logFile}"
						exit 1
					fi
				fi
			else
				echo "File Exists on Server, Verify is off, overriding remote copy" >> "${logFile}"
				copyFileToServer ${localFile} ${localFolder} ${serverDirectory} ${logFile}
				echo "Copy Complete, Verifying File" >> "${logFile}"
			fi
		else
			#File does not exist, lets copy it over
			echo "Copying File to server" >> "${logFile}"
			copyFileToServer ${localFile} ${localFolder} ${serverDirectory} ${logFile}
			echo "Copy Complete, Verifying File" >> "${logFile}"
			if verifyFileWithRemote ${localFile} ${localFolder} ${serverDirectory}
			then
				if [[ "$deleteSource" == "true" ]]
				then
					echo "Files Match, removing local copy" >> "${logFile}"
					rm "${localFolder}${localFile}"
				else
					echo "Files Match" >> "${logFile}"
				fi
			else
				echo "Failed to verify remote copy!!!" >> "${logFile}"
				exit 1
			fi
		fi
	else
		echo "Invalid Local File" >> "${logFile}"
		exit 1
	fi
}

countPlots()
{
	local plotFolder=$1
	local count=`find "${plotFolder}" -name '*.plot' -type f -printf '%f\n' | wc -l`
	echo "${count}"
}

calculateAvailablePlotCount()
{
	availablePlotCount=0
	for plotFolder in ${PLOT_FOLDERS[@]}
	do
		local count=$( countPlots ${plotFolder} )
		availablePlotCount=$((${availablePlotCount}+${count}))
	done
}

getRemoteDriveFreeSpace()
{
	local remoteFolder=$1
	local sshResult=`ssh "${user}"@"${server}" df -P --block-size=1K "${remoteFolder}"`
	echo `echo "${sshResult}" | awk 'NR==2 {print $4}'`
}

#calculate how many plots can fit for a given drivesize in KB
getMaxFitablePlots()
{
	local driveSpaceBuffer=0.05
	local driveSize=$1;
	local amt=$(((($driveSize - ($driveSize*$driveSpaceBuffer)))/$PLOT_FINAL_SIZE))
	local rounded=$( printf %.0f "$amt" )
	echo $rounded
}

getPlotList()
{
	local localFolder=$1
	echo `find "${localFolder}" -name '*.plot' -type f -printf '%f\n'`
}

main()
{
	#main loop, will run till the specified drives are full 
	local runningCopies=0
	declare -A runningDrives
	declare -A runningPlots
	declare -A copyInfoPIDMap
	declare -A copyInfoPlotNamePIDMap
	declare -A copyInfoPlotFolderPIDMap
	declare -A copyInfoRemoteFolderPIDMap
	declare -A copyInfoLogFilePIDMap

	calculateAvailablePlotCount
	echo "Availble for copy: ${availablePlotCount}"
	while [ "$availablePlotCount" -gt "0" ]
	do
		for plotFolder in ${PLOT_FOLDERS[@]}
		do
			if [[ "${runningCopies}" -lt "${MAX_PARALLEL}" ]]
			then
				local plotCap=$( countPlots ${plotFolder} )
				echo "Folder: ${plotFolder}, contains ${plotCap} plots"
				for remoteFolder in ${REMOTE_PLOT_FOLDERS[@]}
				do
					if [[ "${runningCopies}" -lt "${MAX_PARALLEL}" ]]
					then
						local tmpBol="false"
						for k1 v1 in "${(@kv)runningDrives}"
						do
						    if [[ "${runningDrives[$k1]}" == "${remoteFolder}" ]]
						    then
						    	tmpBol="true"
						    fi 
						done
						if [[ "${tmpBol}" == "true" ]]
						then
							echo "job already running for remote folder ${remoteFolder}"
						else
							local remoteFree=$(getRemoteDriveFreeSpace "${remoteFolder}" )
							local maxFit=$(getMaxFitablePlots "${remoteFree}")
							if [[ "${maxFit}" -gt "1" ]]
							then
								echo "Remote Drive: ${remoteFolder} can fit ${maxFit} plots"
								local plotList=($(getPlotList "${plotFolder}"))
								for plotName in ${plotList[@]}
								do
									local tmpBol2="false"
									for k1 v1 in "${(@kv)runningPlots}"
									do
									    if [[ "${runningPlots[$k1]}" == "${plotName}" ]]
									    then
									    	tmpBol2="true"
									    fi 
									done
									if [[ "${tmpBol2}" == "true" ]]
									then
										echo "job already running for plot ${plotName}, skipping"
									else
										echo "Found plot ${plotName}"
										echo "Copying plot to remote folder"
										dateStr=$(echo $(date +%Y_%m_%d_%H_%M_%S))
										local localPath=$(echo ${plotFolder} | tr \/ _)
										local remotePath=$(echo ${remoteFolder} | tr \/ _)
										local plotNameLog=$(echo ${plotName} | tr \. _)
										logFile="${LOG_DIR}/${dateStr}${localPath}_${plotNameLog}${remotePath}log.copylog"
										copyPlot "${plotName}" "${plotFolder}" "${remoteFolder}" "${logFile}" 1>>${logFile} 2>>${logFile}& 
										pid=$!
										copyInfoPIDMap[$pid]=${pid}
										copyInfoPlotNamePIDMap[$pid]=${plotName}
										copyInfoPlotFolderPIDMap[$pid]=${plotFolder}
										copyInfoRemoteFolderPIDMap[$pid]=${remoteFolder}
										copyInfoLogFilePIDMap[$pid]=${logFile}
										runningCopies=$(($runningCopies+1))
										runningDrives[${remoteFolder}]="${remoteFolder}"
										runningPlots[${plotName}]="${plotName}"
										break
									fi
								done
							else
								echo "Remote Drive: ${remoteFolder} can fit ${maxFit} plots, need room for at least 2 for auto copy"
							fi
						fi
					else
						break
					fi
				done
			fi
		done
		clear
		#Wait on the child processes to finish
		for key val in "${(@kv)copyInfoPIDMap}"
		do 
			if [ -n "$key" -a -e /proc/$key ]
			then
				#clear
			    echo "PID is ${key}, Still running"
				echo "Copying Plot: ${copyInfoPlotFolderPIDMap[$key]}${copyInfoPlotNamePIDMap[$key]}"
				echo -e "\tTo Remote Folder: ${copyInfoRemoteFolderPIDMap[$key]}"
				echo -e "\tLog File: ${copyInfoLogFilePIDMap[$key]}"
				echo -e "\t $(tail -1 ${copyInfoLogFilePIDMap[$key]} )"
				echo ""
			else
				#clear
			    echo "PID: ${key} Finished"
			    echo -e "\tRemote Folder: ${copyInfoRemoteFolderPIDMap[$key]}"
			    echo -e "\tPlot Name: ${copyInfoPlotNamePIDMap[$key]}"
				runningCopies=$(($runningCopies-1))
				for k1 v1 in "${(@kv)runningDrives}"
				do
				    if [[ "${runningDrives[$k1]}" == "${copyInfoRemoteFolderPIDMap[$key]}" ]]
				    then
				        unset "runningDrives["${k1}"]"
				    fi 
				done
				for k1 v1 in "${(@kv)runningPlots}"
				do
				    if [[ "${runningPlots[$k1]}" == "${copyInfoPlotNamePIDMap[$key]}" ]]
				    then
				        unset "runningPlots[$k1]"
				    fi 
				done
				unset "copyInfoPIDMap[$key]"
				unset "copyInfoPlotNamePIDMap[$key]"
				unset "copyInfoPlotFolderPIDMap[$key]"
				unset "copyInfoRemoteFolderPIDMap[$key]"
				unset "copyInfoLogFilePIDMap[$key]"
			fi
			
		done
		sleep 5s
		calculateAvailablePlotCount
	done
}

main
exit 0