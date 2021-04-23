#!/bin/zsh
#bail if the user is root, this is too dangerous, comment this out at your own risk. 
if [[ $EUID -eq 0 ]]; then
  echo "This script must NOT be run as root, SET UP PROPER PERMISSIONS!!!!" 1>&2
  exit 1
fi

#function to explain script usage
helpFunction()
{
   echo ""
   echo "Usage: plot -a /path/to/drive1 -b /path/to/drive2 -c /path/to/drive3 -d /path/to/drive4 -e /path/to/drive5"
   echo -e "\t-a First Hard Drive to fill"
   echo -e "\t-b Second Hard Drive to fill"
   echo -e "\t-c Third Hard Drive to fill"
   echo -e "\t-d Fourth Hard Drive to fill"
   echo -e "\t-e Fifth Hard Drive to fill"
   exit 1 # Exit script after printing help
}

#get script args
while getopts "a:b:c:d:e:" opt
do
   case "${opt}" in
      a ) drive1=${OPTARG} ;;
      b ) drive2=${OPTARG} ;;
      c ) drive3=${OPTARG} ;;
      d ) drive4=${OPTARG} ;;
      e ) drive5=${OPTARG} ;;
      ? ) helpFunction ;; # Print helpFunction in case parameter is non-existent
   esac
done

# Print helpFunction in case both parameters are empty
if [ -z "$drive1" ] && [ -z "$drive2" ] && [ -z "$drive3" ] && [ -z "$drive4" ] && [ -z "$drive5" ]
then
   echo "You must specify at least one drive";
   helpFunction
   exit 1
fi

#Arrays used for tracking progress and child processes
declare -A driveFitablePlotsMap
declare -A drivePlotsQueueMap
declare -A tempDriveMaxMap
declare -A tempDriveRunningMap
declare -A tempDrivePIDMap
declare -A delayDriveMap

#default config directory path and config file name
CONFIG_DIRECTORY="$HOME/.chia_scripts/"
CONFIG_FILE="plotter.config"

#LKoad config file, if it exists. Otherwise we create a new config file.
echo "Checking Config"
if [[ -d "$CONFIG_DIRECTORY" ]]
then
	if [[ -f "$CONFIG_DIRECTORY$CONFIG_FILE" ]]
	then
		echo "Config Exists. Loading"
	else
		echo "Error. Config directory is not defined."
		exit 1
	fi
else
	echo "Default Config Directory does not exist. Creating...."

	mkdir "$CONFIG_DIRECTORY"
	if [[ -d "$CONFIG_DIRECTORY" ]]
	then
		echo "Done. Creating Default config....."
		touch "$CONFIG_DIRECTORY$CONFIG_FILE"
		if [[ -f "$CONFIG_DIRECTORY$CONFIG_FILE" ]]
		then
			echo "#Calculated File sizes for file generation DO NOT CHANGE" > "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "PLOT_FINAL_SIZE=$((109000000000/1024))" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "PLOT_TEMP_SIZE=$(( 370000000000/1024))" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "#Temp Drives used in generation, these should be empty fast NVME drives" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "TEMP_DRIVES=(\"\")" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "#chia plotter settings, in general you should only change the thread count and buffer to match your hardware" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "PLOT_BUCKET_SIZE=$((128))" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "PLOT_NUM_THREADS=$((4))" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "PLOT_K_SIZE=$((32))" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "PLOT_BUFFER_SIZE=$((8000))" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "#Path to the chia code base, and where you want the log files, its assumes home directory base on chia setup on the chia github" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "CHIA_ROOT=\"$HOME/chia/chia-blockchain\"" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "LOG_DIR=\"$CONFIG_DIRECTORY/logs\"" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "#delay settings, default is 1.5 hours, this setting is very machine dependent, for slower machines I would change this to at least 7200" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "useDelay=\"true\"" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "delay=5400" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "#file to stop chia generation" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "STOP_FILE=\".stopGen\"" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "" >> "$CONFIG_DIRECTORY$CONFIG_FILE"
			echo "Default Config Created"
		else
			echo "Error. Failed to create config file"

			exit 1
		fi
	else
		echo "Default Config Directory does not exist. Creating...."
		exit 1
	fi
fi

#load the config file
source "$CONFIG_DIRECTORY$CONFIG_FILE"

if [ "${#TEMP_DRIVES[@]}" -lt "1" ]
then
	echo "Please speciy at least one TEMP_DRIVE in plotter.config"
	echo "File Located at: $CONFIG_DIRECTORY$CONFIG_FILE"
fi
for tempDrive in ${TEMP_DRIVES[@]}
do
	if [ "$(ls -A ${tempDrive})" ]
	then
	    echo "WARN ${tempDrive} is not empty"
		echo "Would you like to clear existing tmp files in (${tempDrive})?"
		if read -q "?"
		then
			echo
			trimmedPath=`echo $tempDrive | sed 's/ *$//g'`
			tmpFilesPath="${trimmedPath}/*.tmp"
			echo "Deleting ${tmpFilesPath}"
		    rm "${trimmedPath}"/*.tmp 2>/dev/null
		fi
	fi
done

#gets the free space in KB for a give directory path
getDriveCapacity()
{
	local drive=$1
	echo `df -P --block-size=1K $drive | awk 'NR==2 {print $4 + $3}'`
}

#gets the free space in KB for a give directory path
getDriveFreeSpace()
{
	local drive=$1
	echo `df -P --block-size=1K $drive | awk 'NR==2 {print $4}'`
}

#gets space used by plots
getUsedPlotSpace()
{
	local drive=$1
	echo `find $drive -maxdepth 1 -type f -name '*.plot' | tr "\n" "\0" | du -cs --files0-from=- | tail -n 1 | awk '{print $1}'`
}

#calculate how many plots can fit for a given drivesize in KB
getMaxFitablePlots()
{
	local driveSize=$1;
	local amt=$((${driveSize}/${PLOT_FINAL_SIZE}))
	local rounded=$( printf %.0f "$amt" )
	echo $rounded
}

#calculate how many plots can be generated for the given drivesize in KB
getMaxTempPlots()
{
	local driveSize=$1;
	local amt=$((${driveSize}/${PLOT_TEMP_SIZE})) 
	local rounded=$( printf %.0f "$amt" )
	echo $rounded
}

checkDrive()
{
	local drive=$1
	#get total size of drive
	capacity=$( getDriveCapacity ${drive} )
	#get space used by complete plots
	usedPlotSpace=$( getUsedPlotSpace ${drive} )
	#get estimated space used by remain queue
	numInQueue=${drivePlotsQueueMap[$drive]}
	#use this size to determine how many plots can fit 
	estimatedUseFromQueue=$(( $numInQueue * $PLOT_FINAL_SIZE ))
	estimatedFreeSpace=$(( $capacity - $usedPlotSpace - $estimatedUseFromQueue ))
	driveFitablePlotsMap[$drive]=$( getMaxFitablePlots "$estimatedFreeSpace" )
	echo "$drive can support $driveFitablePlotsMap[$drive] plots"
}

checkDrives()
{
	if [[ -d "$drive1" ]]
	then
		checkDrive "$drive1"
	fi
	if [[ -d "$drive2" ]]
	then
		checkDrive "$drive2"
	fi
	if [[ -d "$drive3" ]]
	then
		checkDrive "$drive3"
	fi
	if [[ -d "$drive4" ]]
	then
		checkDrive "$drive4"
	fi
	if [[ -d "$drive5" ]]
	then
		checkDrive "$drive5"
	fi
}

initDrives()
{
	if [[ -d "$drive1" ]]
	then
		driveFitablePlotsMap[$drive1]=0
		drivePlotsQueueMap[$drive1]=0
	fi
	if [[ -d "$drive2" ]]
	then
		driveFitablePlotsMap[$drive2]=0
		drivePlotsQueueMap[$drive2]=0
	fi
	if [[ -d "$drive3" ]]
	then
		driveFitablePlotsMap[$drive3]=0
		drivePlotsQueueMap[$drive3]=0
	fi
	if [[ -d "$drive4" ]]
	then
		driveFitablePlotsMap[$drive4]=0
		drivePlotsQueueMap[$drive4]=0
	fi
	if [[ -d "$drive5" ]]
	then
		driveFitablePlotsMap[$drive5]=0
		drivePlotsQueueMap[$drive5]=0
	fi
}

checkTempDrives()
{
	#Loop through the temp drives and prompt the user if they are not empty
	#after emptying the drives we check howe many plots they can hold and save it to the mappings
	local tempPlotSpace=0
	for tempDrive in ${TEMP_DRIVES[@]}
	do
		tmpFreeSpace=$( getDriveFreeSpace ${tempDrive} )
		tmpPlotAmt=$( getMaxTempPlots ${tmpFreeSpace} )
		echo "${tempDrive} can support $tmpPlotAmt plots"
		tempPlotSpace=$(($tempPlotSpace+$tmpPlotAmt))
		tempDriveMaxMap[${tempDrive}]=${tmpPlotAmt} 
		tempDriveRunningMap[${tempDrive}]=0
		delayDriveMap[${tempDrive}]=0
	done
	echo "Temp Drives can Generate $tempPlotSpace plots"
}

driveCanFitPlots()
{
	local drive=$1
	if [ ! -z "$driveFitablePlotsMap[$drive]" ] && [ "$driveFitablePlotsMap[$drive]" -gt "0" ] 
	then
		return 0
	else
		return 1
	fi
}

startChia()
{
	for tempDrive in ${TEMP_DRIVES[@]}
		do
		#check the temp drive has more space, and fill it till it does or there is not more room for plots
		while [[ "${tempDriveRunningMap[${tempDrive}]}" -lt "${tempDriveMaxMap[${tempDrive}]}" ]]
		do
			dateStr=$(echo $(date +%Y_%m_%d_%H_%M_%S))
			driveLogPath=$(echo ${tempDrive} | tr \/ _)
			logFile="${LOG_DIR}/${dateStr}${driveLogPath}_${tempDriveRunningMap[${tempDrive}]}.log"
			#Try to distribute the 
			tmpSaveDir=""
			if [ "${driveFitablePlotsMap[$drive1]}" -gt "${drivePlotsQueueMap[$drive1]}" ] && ([ "${drivePlotsQueueMap[$drive1]}" -le "${drivePlotsQueueMap[$drive2]}" ] && [ "${driveFitablePlotsMap[$drive2]}" -gt "${drivePlotsQueueMap[$drive2]}" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "${drivePlotsQueueMap[$drive2]}" ] ) && ([ "${drivePlotsQueueMap[$drive1]}" -le "${drivePlotsQueueMap[$drive3]}" ] && [ "${driveFitablePlotsMap[$drive3]}" -gt "${drivePlotsQueueMap[$drive3]}" ] || [ "${driveFitablePlotsMap[$drive3]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive3]}" -eq "${drivePlotsQueueMap[$drive3]}" ] ) && ([ "${drivePlotsQueueMap[$drive1]}" -le "${drivePlotsQueueMap[$drive4]}" ] && [ "${driveFitablePlotsMap[$drive4]}" -gt "${drivePlotsQueueMap[$drive4]}" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "${drivePlotsQueueMap[$drive4]}" ] ) && ([ "${drivePlotsQueueMap[$drive1]}" -le "${drivePlotsQueueMap[$drive5]}" ] && [ "${driveFitablePlotsMap[$drive5]}" -gt "${drivePlotsQueueMap[$drive5]}" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "${drivePlotsQueueMap[$drive5]}" ] ) #fill drive 1
			then
				tmpSaveDir="${drive1}"
				drivePlotsQueueMap[${drive1}]=$((${drivePlotsQueueMap[${drive1}]}+1))
			elif [[ "${driveFitablePlotsMap[$drive2]}" -gt "${drivePlotsQueueMap[$drive2]}" ]] && ([ "${drivePlotsQueueMap[$drive2]}" -le "${drivePlotsQueueMap[$drive1]}" ] && [ "${driveFitablePlotsMap[$drive1]}" -gt "${drivePlotsQueueMap[$drive1]}" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "${drivePlotsQueueMap[$drive1]}" ] ) && ([ "${drivePlotsQueueMap[$drive2]}" -le "${drivePlotsQueueMap[$drive3]}" ] && [ "${driveFitablePlotsMap[$drive3]}" -gt "${drivePlotsQueueMap[$drive3]}" ] || [ "${driveFitablePlotsMap[$drive3]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive3]}" -eq "${drivePlotsQueueMap[$drive3]}" ] ) && ([ "${drivePlotsQueueMap[$drive2]}" -le "${drivePlotsQueueMap[$drive4]}" ] && [ "${driveFitablePlotsMap[$drive4]}" -gt "${drivePlotsQueueMap[$drive4]}" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "${drivePlotsQueueMap[$drive4]}" ] ) && ([ "${drivePlotsQueueMap[$drive2]}" -le "${drivePlotsQueueMap[$drive5]}" ] && [ "${driveFitablePlotsMap[$drive5]}" -gt "${drivePlotsQueueMap[$drive5]}" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "${drivePlotsQueueMap[$drive5]}" ] ) #fill drive 2
			then
				tmpSaveDir="${drive2}"
				drivePlotsQueueMap[${drive2}]=$((${drivePlotsQueueMap[${drive2}]}+1))
			elif [[ "${driveFitablePlotsMap[$drive3]}" -gt "${drivePlotsQueueMap[$drive3]}" ]] && ([ "${drivePlotsQueueMap[$drive3]}" -le "${drivePlotsQueueMap[$drive1]}" ] && [ "${driveFitablePlotsMap[$drive1]}" -gt "${drivePlotsQueueMap[$drive1]}" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "${drivePlotsQueueMap[$drive1]}" ] ) && ([ "${drivePlotsQueueMap[$drive3]}" -le "${drivePlotsQueueMap[$drive2]}" ] && [ "${driveFitablePlotsMap[$drive2]}" -gt "${drivePlotsQueueMap[$drive2]}" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "${drivePlotsQueueMap[$drive2]}" ] ) && ([ "${drivePlotsQueueMap[$drive3]}" -le "${drivePlotsQueueMap[$drive4]}" ] && [ "${driveFitablePlotsMap[$drive4]}" -gt "${drivePlotsQueueMap[$drive4]}" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "${drivePlotsQueueMap[$drive4]}" ] ) && ([ "${drivePlotsQueueMap[$drive3]}" -le "${drivePlotsQueueMap[$drive5]}" ] && [ "${driveFitablePlotsMap[$drive5]}" -gt "${drivePlotsQueueMap[$drive5]}" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "${drivePlotsQueueMap[$drive5]}" ] )  #fill drive 3
			then
				tmpSaveDir="${drive3}"
				drivePlotsQueueMap[${drive3}]=$((${drivePlotsQueueMap[${drive3}]}+1))
			elif [[ "${driveFitablePlotsMap[$drive4]}" -gt "${drivePlotsQueueMap[$drive4]}" ]] && ([ "${drivePlotsQueueMap[$drive4]}" -le "${drivePlotsQueueMap[$drive1]}" ] && [ "${driveFitablePlotsMap[$drive1]}" -gt "${drivePlotsQueueMap[$drive1]}" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "${drivePlotsQueueMap[$drive1]}" ] ) && ([ "${drivePlotsQueueMap[$drive4]}" -le "${drivePlotsQueueMap[$drive2]}" ] && [ "${driveFitablePlotsMap[$drive2]}" -gt "${drivePlotsQueueMap[$drive2]}" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "${drivePlotsQueueMap[$drive2]}" ] ) && ([ "${drivePlotsQueueMap[$drive4]}" -le "${drivePlotsQueueMap[$drive3]}" ] && [ "${driveFitablePlotsMap[$drive3]}" -gt "${drivePlotsQueueMap[$drive3]}" ] || [ "${driveFitablePlotsMap[$drive3]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "${drivePlotsQueueMap[$drive3]}" ] )&& ([ "${drivePlotsQueueMap[$drive4]}" -le "${drivePlotsQueueMap[$drive5]}" ] && [ "${driveFitablePlotsMap[$drive5]}" -gt "${drivePlotsQueueMap[$drive5]}" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive5]}" -eq "${drivePlotsQueueMap[$drive5]}" ] )  #fill drive 4
			then
				tmpSaveDir="${drive4}"
				drivePlotsQueueMap[${drive4}]=$((${drivePlotsQueueMap[${drive4}]}+1))
			elif [[ "${driveFitablePlotsMap[$drive5]}" -gt "${drivePlotsQueueMap[$drive4]}" ]] && ([ "${drivePlotsQueueMap[$drive5]}" -le "${drivePlotsQueueMap[$drive1]}" ] && [ "${driveFitablePlotsMap[$drive1]}" -gt "${drivePlotsQueueMap[$drive1]}" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive1]}" -eq "${drivePlotsQueueMap[$drive1]}" ] ) && ([ "${drivePlotsQueueMap[$drive5]}" -le "${drivePlotsQueueMap[$drive2]}" ] && [ "${driveFitablePlotsMap[$drive2]}" -gt "${drivePlotsQueueMap[$drive2]}" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive2]}" -eq "${drivePlotsQueueMap[$drive2]}" ] ) && ([ "${drivePlotsQueueMap[$drive5]}" -le "${drivePlotsQueueMap[$drive3]}" ] && [ "${driveFitablePlotsMap[$drive3]}" -gt "${drivePlotsQueueMap[$drive3]}" ] || [ "${driveFitablePlotsMap[$drive3]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "${drivePlotsQueueMap[$drive3]}" ] ) && ([ "${drivePlotsQueueMap[$drive5]}" -le "${drivePlotsQueueMap[$drive4]}" ] && [ "${driveFitablePlotsMap[$drive4]}" -gt "${drivePlotsQueueMap[$drive4]}" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "0" ] || [ "${driveFitablePlotsMap[$drive4]}" -eq "${drivePlotsQueueMap[$drive4]}" ] )  #fill drive 5
			then
				tmpSaveDir="${drive5}"
				drivePlotsQueueMap[${drive5}]=$((${drivePlotsQueueMap[${drive5}]}+1))
			else 
				echo "No Available Save/Temp Directory: Waiting for drive rescan"
				echo "Drive1: ${driveFitablePlotsMap[${drive1}]}/${driveFitablePlotsMap[${drive1}]} Plots(Queued/Fitable)"
				echo "Drive2: ${driveFitablePlotsMap[${drive2}]}/${driveFitablePlotsMap[${drive2}]} Plots(Queued/Fitable)"
				echo "Drive3: ${driveFitablePlotsMap[${drive3}]}/${driveFitablePlotsMap[${drive3}]} Plots(Queued/Fitable)"
				echo "Drive4: ${driveFitablePlotsMap[${drive4}]}/${driveFitablePlotsMap[${drive4}]} Plots(Queued/Fitable)"
				echo "Drive5: ${driveFitablePlotsMap[${drive5}]}/${driveFitablePlotsMap[${drive5}]} Plots(Queued/Fitable)"
				break
			fi
			if [[ "${useDelay}" -eq "true" ]]
			then
				delayCnt=$((${delayDriveMap[${tempDrive}]}))
				delaySeconds=$(( $delayCnt * $delay ))
				delayDriveMap[${tempDrive}]=$((${delayDriveMap[${tempDrive}]}+1))
				(sleep ${delaySeconds}; chia plots create -n 1 -k ${PLOT_K_SIZE} -b ${PLOT_BUFFER_SIZE} -r ${PLOT_NUM_THREADS} -u ${PLOT_BUCKET_SIZE} -t ${tempDrive} -2 ${tempDrive} -d ${tmpSaveDir} 1>${logFile} 2>${logFile}) &
			else
				echo "NO DELAY"
				chia plots create -n 1 -k ${PLOT_K_SIZE} -b ${PLOT_BUFFER_SIZE} -r ${PLOT_NUM_THREADS} -u ${PLOT_BUCKET_SIZE} -t ${tempDrive} -2 ${tempDrive} -d ${tmpSaveDir} 1>${logFile} 2>${logFile} &
			fi
			pid=$!
			tempDrivePIDMap[$pid]=${tempDrive}
			logFilePIDMap[$pid]=${logFile}
			saveDirPIDMap[$pid]=${tmpSaveDir}
			tempDriveRunningMap[${tempDrive}]=$((${tempDriveRunningMap[${tempDrive}]}+1))
			echo "Started Ploting Process PID=${pid}"
		done
	done
}

main() 
{
	#fecth current directory so we can put the user back later
	CUR_DIR=`pwd`
	initDrives
	checkDrives

	#in case of existing virtual enviroment we need to exit, also suppress output 
	./deactivate 1>/dev/null 2>/dev/null &

	#enter chia virtual enviroment
	cd $CHIA_ROOT
	. ./activate

	#verify we are in the virtual chia enviroment
	virtualPath=`env | grep -i virtual`
	if [[ -z ${(q)virtualPath} ]]
	then
		echo "Failed to Enter the Virtual Enviroment, please check your CHIA_ROOT is correct"
		return 1
	fi
	#init array maps to manage child processes and drive usage

	#main loop, will run till the specified drives are full 
	loopCnt=0 #sanity check for now 
	declare -A logFilePIDMap
	declare -A saveDirPIDMap
	while driveCanFitPlots "$drive1" || driveCanFitPlots "$drive2" || driveCanFitPlots "$drive3" || driveCanFitPlots "$drive4" || driveCanFitPlots "$drive5" && [ "$loopCnt" -lt "2" ]
	do
		checkTempDrives
		checkDrives
		#loop to start threads for generation
		echo "Starting Plotting Process"

		startChia

		local running=0
		while [ "$running" -lt "1" ]
		do
			clear
			#Wait on the child processes to finish
			for key val in "${(@kv)tempDrivePIDMap}"
			do 
				if [ -n "$key" -a -e /proc/$key ]
				then
					echo "PID is ${key}, still running"
					echo -e "\tTemp Directory: ${val}"
					echo -e "\tSave Directory: ${saveDirPIDMap[${key}]}"
					echo -e "\tK-Size: ${PLOT_K_SIZE}, buffer: ${PLOT_BUFFER_SIZE}, threads: ${PLOT_NUM_THREADS}, buckets: ${PLOT_BUCKET_SIZE}"
					echo -e "\tLog file located at: ${logFilePIDMap[${key}]}"
				else
					#When One Finishes attempt to queue up another
				    echo "PID: ${key} Finished"
					tempDrive=${tempDrivePIDMap[${key}]}
					tempDriveRunningMap[${tempDrive}]=$((${tempDriveRunningMap[${tempDrive}]}-1))
					delayDriveMap[${tempDrive}]=0
					saveDir=${saveDirPIDMap[${key}]}
					drivePlotsQueueMap[${saveDir}]=$((${drivePlotsQueueMap[${saveDir}]}-1))
					if [[ -f "$CUR_DIR/$STOP_FILE" ]]
					then
						echo "Stop File Detected. Preventing new Chia Threads from starting."
					else
						checkDrives
						startChia
					fi
					unset "tempDrivePIDMap[${key}]"
					unset "saveDirPIDMap[${key}]"
					unset "logFilePIDMap[${key}]"
				fi
			done
			sleep 30s
			if [ "${#tempDrivePIDMap[@]}" -lt "1" ]
			then
				running=1
			fi
		done
		for key val in "${(@kv)tempDrivePIDMap}"
		do 
			unset "tempDrivePIDMap[$key]"
		done
		echo "Ploting Finished"
		loopCnt=$(($loopCnt+1))
		if read -t 30 "Press any key to continue plotting or wait 30 seconds"
		then
			echo "Ploting Resuming"	
		else
			echo "Exiting"
			running=1
		fi
	done

	#leave the venv and exit the program
	deactivate
	virtualPath=`env | grep -i virtual`
	if [[ -z ${(q)virtualPath} ]]
	then
		echo "Failed to exit the Virtual Enviroment, please check your CHIA_ROOT is correct"
		cd $CUR_DIR
	else
		cd $CUR_DIR
	fi
}

main

unset tempDriveMaxMap
unset tempDriveRunningMap
unset tempDrivePIDMap
unset driveFitablePlotsMap
unset drivePlotsQueueMap
exit 0