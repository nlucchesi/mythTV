#!/usr/bin/env bash
#
# ****************************************************************************************
# *  Process MythTV recordings to:
# *
# *  1. Flag and remove commercials
# *
# *  2. Transcode video to H.264 but retain the original audio.
# *     (If you use an HDHomeRun like I do, then audio will probably be AC3
# *     and doesn't need transcoding.)
# *
# *  3. Update database with name, size, and location of H.264 file.
# *
# *  4. Create listing compatible with naming convention for 
# *     Plex Media Server (PMS):
# *     - Symlink transcoded video file to a pretty name in a different directory
# *     - Prune broken symlinks, empty directories (due to deleting recordings).
# *   
#
#
# ****************************************************************************************
# *  History
# *
# *  2016-03-06
# *  Added "debug" as a log level.  Made sure that PMS name is unique when subtitle is
# *  empty or all spaces.
# *
# *  2016-03-06
# *  Added "debug" as a log level.
# *
# *  2016-01-07
# *  Modified to handle edge cases:
# *  - Bypass commercial flagging and removal if recording doesn't have .mpg extension.
# *  - Tailor commercial flagging and removal based on value of recorded.commflagged.
# *  - Add recording to PMS library regardless of success of either:
# *    • Commercial removal
# *    • H264 encoding
# *
# *  2016-01-07
# *  Added function logIfLogging to log string unless logging is turned off.
# *
# *  2016-01-06
# *  Added function logVar to write variable values to log file.
# *
# *  2015-12-30
# *  Added function logIt to write strings to log file.
# *
# *  2015-04-14
# *  Created based on these scripts:
# *  http://tech.surveypoint.com/posts/mythtv-transcoding-with-handbrake/
# *  https://forums.plex.tv/discussion/141863/
#
#
# ****************************************************************************************
# *  References for commands used in this script
# *  
# *  HandbrakeCLI
# *  https://trac.handbrake.fr/wiki/CLIGuide
# *  https://trac.handbrake.fr/wiki/BuiltInPresets
# *  https://www.mythtv.org/wiki/Mythbrake
# *  
# *  mythutil
# *  https://www.mythtv.org/wiki/Mythutil
# *  
# *  mythtranscode
# *  https://www.mythtv.org/wiki/Mythtranscode#Remove_commercials_from_an_MPEG2_recording
# *  
# *  mythcommflag
# *  https://www.mythtv.org/wiki/mythcommflag#Modifying_Commercial_Detection_with_Settings
# *  
# *  plex
# *  https://support.plex.tv/hc/en-us/articles/201242707-Plex-Media-Scanner-via-Command-Line
# *  https://support.plex.tv/hc/en-us/categories/200028098-Media-Preparation
# *  https://support.plex.tv/hc/en-us/articles/201638786-Plex-Media-Server-URL-Commands
# *
# *  MySQL (mysql_config_editor)
# *  https://dev.mysql.com/doc/refman/5.6/en/mysql-config-editor.html
# *  https://stackoverflow.com/questions/19900399/stop-warning-from-mysql-terminal
# *  https://stackoverflow.com/questions/20751352/suppress-warning-messages-using-mysql-from-within-terminal-but-password-written
#
#
# ****************************************************************************************
# *  References for Mythconverg Tables
# *  
# *  recorded
# *  https://www.mythtv.org/wiki/Recorded_table
# *  
# 
# 
# ****************************************************************************************
# *  Usage
# *
# *  Enter this in MythTV Job Queue:
# *  /path/to/script/mythpostprocess.sh "%CHANNEL_ID%" "%START_TIME_UTC%"
# *
# *  The recording is identified by:
# *  - CHANNEL_ID     = 4-digit channel ID
# *  - START_TIME_UTC = 14-digit UTC datetime code (YYYYMMDDDHHMMSS)
# *
#
#
# ****************************************************************************************
# *  Assumptions
# *
# *  1.	TV and Movies are in separate STORAGEGROUPs as follows:
# *
# *  	Media Type		STORAGEGROUPs
# * 	Tv				LiveTV, Default
# *  	Movies			VIEDEO
# *
# *  2.	The following packages (and their dependencies) are installed:
# *		- HandBrakeCLI
# *		
# *  3. mysql_config_editor used to create --login-path
# *		
# *
#
# ****************************************************************************************
# *  Variable Naming Convention
# *
# *  ALL_CAPS = Constant
# *  camelCase = Variable
# *	
# *	 Variables containing values from database are named as:
# *  <table name>_<column name>
# *
#
# ****************************************************************************************
# *  Customization
# *
# *  Set these script parameters based on your installation.
# *
# 
# Name of this script and its Path
declare -r SCRIPT_NAME="h264PMS"
declare -r SCRIPT_PATH="/usr/local/src/mythtv"
#
# Desired job priority for this script.
declare -r SCRIPT_PROCESS_NI_DESIRED="19"
#
# Path, extension, and name appended to this script's log file.
declare -r LOG_PATH="/var/log/mythtv"
declare -r LOG_EXT="log"
declare -r LOG_SUFFIX_FAIL="FAILED"
#
# Path to logs queued for mailing
# (Create a Task in FreeNAS GUI to mail  files in this directory.)
declare -r EMAIL_QUEUE_PATH="$LOG_PATH/emailQueue"
#
# Days before deleting all log files in $LOG_PATH
# (Includes log files created by other MythTV scripts and executables.)
# (Leave empty to never delete log files.
declare -r LOG_DAYS_TO_KEEP="4"
#
# Path to MythTV transcoding tools
declare -r MYTHTV_PATH="/usr/local/bin"
#
# Path to directory for temporary files.
# (Used for intermediary, commercial-free MPEG2 video files.)
declare -r MEDIA_PATH_TMP="/media/tmp"
#
# MySQL database login information (for mythconverg database)
# (Assumes path already created with mysql_config_editor)  
declare -r MYSQL_PATH="mythtv"
#
# File containing custom parameters for detecting commercials.
# (Set to empty to run mythcommflag without overriding settings.)
declare -r MYTHCOMMFLAG_OVERRIDES="$SCRIPT_PATH/mythflagoverride.txt"
# 
# Directory for PMS-formatted symbolic links to recordings
declare -r MEDIA_PATH_PMS="/media/pms"
declare -r MEDIA_PATH_PMS_TV="$MEDIA_PATH_PMS/TV Shows"
declare -r MEDIA_PATH_PMS_MOVIES="$MEDIA_PATH_PMS/Movies"
#
# URL prefix for PMS.
# (Used to Update PMS Library with recording specified by arguments to script.)
declare -r PMS_URL="http://10.10.49.14:32400"
#
# PMS section numbers
declare -r PMS_SECTION_ID_MOVIE="4"
declare -r PMS_SECTION_ID_TV="5"
# How to find these values:
# - Browse to the desired library on your PMS
#   http://<ipAddress>:32400/library/sections
# - XML will be displayed with the heirarchy
#   <MediaContainer ... >
#     <Directory ... key="<digits>" ... >
#       <Location ... >
# - The Directory key digits are the section numbers
#
# Myth storage groups
declare -r STORAGEGROUP_MOVIE="Videos"
declare -r STORAGEGROUP_LIVETV="LiveTV"
declare -r STORAGEGROUP_DEFAULT="Default"
#
# File extension for H264-encoded file created by this script.
declare -r H264_EXTENSION="mp4"
#
# Options for individual bash commands
declare -r CMD_LS_OPTIONS="-lAh"
#
# Permissions for files created by this script.
declare -r FILE_OWNER="mythtv"
declare -r FILE_GROUP="mythtv"
#
# Available Logging Modes
declare -r LOGGING_NONE="0"
declare -r LOGGING_MINIMAL="1"
declare -r LOGGING_VERBOSE="2"
declare -r LOGGING_DEBUG="3"
#
# Media Types
declare -r MEDIA_TYPE_EPISODE="EP"
declare -r MEDIA_TYPE_SPECIAL="SH"
declare -r MEDIA_TYPE_MOVIE="MV"
#
# Which Level of logging do you want?
# Logging includes all levels below this choice.
declare -r LOGGING_MODE="$LOGGING_MINIMAL"
#
# Do you want log entries to appear in terminal window when running this script from the command line?
declare -r LOGGING_ECHO=true
#
# Available Conditions Under Which to Mail Log File.
declare -r EMAIL_LOG_NEVER="0"
declare -r EMAIL_LOG_ERROR="1"
declare -r EMAIL_LOG_ALWAYS="2"
#
# Under Which Conditions Do You Want to Mail the Log File?
declare -r EMAIL_LOG_MODE=$EMAIL_LOG_ALWAYS
#
# List the chanID of the Channels that you want to exclude from commercial removal.
# (For example, exclude all PBS channels.)
# (Leave empty if you want to rely solely on the database settings.)
declare -r CHANID_SEPARATOR=":"
myScrap="$CHANID_SEPARATOR"
myScrap+="1111$CHANID_SEPARATOR"
myScrap+="1112$CHANID_SEPARATOR"
myScrap+="1113$CHANID_SEPARATOR"
myScrap+="1114$CHANID_SEPARATOR"
myScrap+="1201$CHANID_SEPARATOR"
myScrap+="1202$CHANID_SEPARATOR"
myScrap+="1203$CHANID_SEPARATOR"
declare -r CHANID_COMMERCIAL_FREE="$myScrap"
#
#
# Normal return code as well as anomalies that indicate sucess. 
ERROR_CODE_THRESHOLD_NORMAL="0"
# For some reason ... Successful MySQL commands have return codes of 1.
ERROR_CODE_THRESHOLD_MYSQL="1"
# Return codes under 128 indicate the number of commercials flagged.
# (https://github.com/MythTV/mythtv/blob/master/mythtv/libs/libmythbase/exitcodes.h)
ERROR_CODE_THRESHOLD_COMMFLAG="127"
#
#
# You shouldn't need to change anything below here.
#
#
# ****************************************************************************************
# *  Step 0
# *  Define Functions and Initialize Constants and Variables.
# *
#
#
nowUTC() {
# Returns string of UTC in format: yyyy-mm-dd_hh:mm:ss
# Must be called as: $( nowUTC )
# (Because bash doesn't support functions returning strings.)
	echo $( date -u "+%Y-%m-%d_%H:%M:%S" )
}
logIt() {
# Log string.
	local logMsg="$(date +%F_%T)"" $*"
	if [ $LOGGING_ECHO ] ; then
		echo "$logMsg"
	fi
	echo "$logMsg" >> "$logCurrentFullName"
	return 0
}
logIfLogging() {
# logIt unless logging mode is none.
	if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
	then
		logIt "$*"
	fi
	return 0
}
logIfVerbose() {
# logIt only when logging mode is verbose or higher.
	if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
	then
		logIt "$*"
	fi
	return 0
}
logVar() {
# Log the name and value of a variable.
	local varName="$*"
	eval varValue="\$$varName"
	logIt "$varName=\"$varValue\""
	return 0
}
logVarIfVerbose() {
# logVar only when logging mode is verbose or higher.
	if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
	then
		logVar "$*"
	fi
	return 0
}
logVarIfLogging() {
# logVar only when logging mode is verbose or higher.
	if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
	then
		logVar "$*"
	fi
	return 0
}
logFail() {
# Log termination messages and rename log file to reflect script failure.
	logIt "Terminating script due to error." 
	logIt "Log file renamed: $LOG_FILE -> $LOG_FILE_FAILED"
	mv "$LOG_FILE" "$LOG_FILE_FAILED"
	#
	# Update pointer to log file so that log functions continue to work.
	logCurrentFullName="$LOG_FILE_FAILED"
	#
	# Check whether to email log file.
	if [[ $EMAIL_LOG_MODE != "$EMAIL_LOG_NEVER" ]]
	then
		# Mail log file to root.
		queueLogForEmail 
	fi
	exit 0
}
runCmd() {
# Execute the string passed to it using eval.
# (Continues on error.)
	#
	# Create and initialize local variables.
	local cmdString="$1"
	local cmdLogMsg="$2"
	local cmdReturnCode=""
	local cmdMysql="mysql "
	local cmdMythcommflag="$MYTHTV_PATH/mythcommflag "
	local cmdErrorThreshold=""
	if [[ $cmdString == "$cmdMysql"* ]]
	then
		cmdErrorThreshold="$ERROR_CODE_THRESHOLD_MYSQL" 
	else
		if [[ $cmdString == "$cmdMythcommflag"* ]]
		then
			cmdErrorThreshold="$ERROR_CODE_THRESHOLD_COMMFLAG"
		else
			cmdErrorThreshold="$ERROR_CODE_THRESHOLD_NORMAL"
		fi 
	fi
	#
	# Execute command and check return code.
	eval "$cmdString"
	cmdReturnCode=$?
	if [[ $cmdReturnCode -gt "$cmdErrorThreshold" ]]
	then
		# Log command failed with return code. 
		logIt "$cmdLogMsg failed with error: \"$cmdReturnCode\""
		logIt "Command: \"$cmdString\""
	else
		# Log command succeeded. 
		logIfVerbose "Command: \"$cmdString\""
		logIfLogging "$cmdLogMsg succeeded."
	fi
	return "$cmdReturnCode"
}
chownMythtv() {
# Change UNIX owner and group for file to mythtv.
# (Needed in case this script could be run from an account other than mythtv).
# Argument is a string containing the fully-qualified file path and name.
	#
	# Create and initialize local variables.
	local filePathAndName="$*"
	local cmdString="chown $FILE_OWNER:$FILE_GROUP \"$filePathAndName\""
	local cmdReturnCode=""
	#
	# Check whether file exists.
	# (-e should include symlinks but it's not doing so for me.)
	if [ -e "$filePathAndName" ] ||  [ -L "$filePathAndName" ]
	then
		logIfVerbose "Updating ownership of $filePathAndName ..."
		cmdLogMsg="Ownership change of \"$filePathAndName\""
		runCmd "$cmdString" "$cmdLogMsg"
		cmdReturnCode=$?
	else
		# File not found.
		logIt "Error in function chownMythtv: File not found."
		logVar "filePathAndName"
		logFail
	fi
	return "$cmdReturnCode"
}
queueLogForEmail() {
# Queue log ($logCurrentFullName) for email by FreeNAS Task script.
	#
	# Create and initialize local variables.
	local cmdReturnCode=""
	#
	# Check whether EMAIL_QUEUE_PATH is empty or only spaces.
	if [ -z "${EMAIL_QUEUE_PATH// }" ] 
	then 
		# Directory for email queue has NOT been set.
		logIt "Error in function queueLogForEmail: Email queue directory is empty."
		logVar "EMAIL_QUEUE_PATH"
	else
		#
		# Create directory for queuing logs to be emailed by FreeNAS Task.
		mkdir -p "$EMAIL_QUEUE_PATH"
		#
		# Copy log to queue.
		cp "$logCurrentFullName" "$EMAIL_QUEUE_PATH"
		#
		# Change permissions on all queued logs to read and write all.
		chmod a+rw -R "$EMAIL_QUEUE_PATH"
	fi
	#
	# Return
	return 0
}
makeFilenameSafe() {
# Remove characters which can NOT be used in file or directory names.
# (Sets safeFilename with result)
	#
	# Create and initialize local variables.
	local originalFilename="$*"
	local cmdReturnCode=""
	#
	# Keep only hyphen, alpha, digit, underscore, and space.
	# (Substitute underscore ("_") for all others.)  
	# (Hyphen must be at beginning of pattern: http://wiki.bash-hackers.org/syntax/pattern )
	# (PMD requires parentheses and spaces: https://support.plex.tv/hc/en-us/categories/200028098-Media-Preparation ) 
	safeFilename=${originalFilename//[!-A-Za-z0-9._ ()]/_}
	cmdReturnCode=$?
	return "$cmdReturnCode"
}
#
# Meaning of RECORDED.COMMFLADGGED Values
declare -r COMMFLAG_NOT_FLAGGED=0
declare -r COMMFLAG_DONE=1
declare -r COMMFLAG_PROCESSING=2
declare -r COMMFLAG_COMM_FREE_CHANNEL=3
#
# Value of database boolean variables.
declare -r DB_TINYINT_YES=1
declare -r DB_TINYINT_NO=0
#
# File extension for original recorded file created by MythTV.
declare -r ORIGINAL_EXTENSION="mpg"
#
# PID of this process (used to trottle script's CPU usage).
declare -r SCRIPT_PROCESS_ID=$$
#
# Capture script parameter values
declare -r CHANNEL_ID=$1
declare -r START_TIME_UTC=$2
#
# Create constants for MySQL commands.
declare -r MYSQL_CMD="mysql --login-path=mythtv -D mythconverg -se"
declare -r MYSQL_WHERE=" chanid=\"$CHANNEL_ID\" AND starttime=\"$START_TIME_UTC\" "
#
# Base name of log files reverse the order of channel and datetime.
declare -r LOG_FILE=$LOG_PATH/$SCRIPT_NAME.$2.$1.$LOG_EXT
declare -r LOG_FILE_FAILED=$LOG_PATH/$SCRIPT_NAME.$2.$1."$LOG_SUFFIX_FAIL".$LOG_EXT
#
# Keep track of where log file is.
logCurrentFullName="$LOG_FILE"
#
# Log entry into script.
logMsg="Running script: $0 $*"
logIfLogging "$logMsg"  
logVarIfVerbose "CHANNEL_ID"
logVarIfVerbose "START_TIME_UTC"
#
# Check whether there are any records for this combination of channel and start time.
logIfVerbose "Retrieving and formatting recording metadata from mythconverg database ..." 
declare -r RECORDED_COUNT=$( $MYSQL_CMD "SELECT count(*) FROM recorded WHERE $MYSQL_WHERE;" )
if [[ $RECORDED_COUNT -ne 1 ]] 
then
	logIt "Error: There should be exactly one recording for this channel and time."
	logVar "CHANNEL_ID"
	logVar "START_TIME_UTC"
	logVar "RECORDED_COUNT"
	logFail
fi
#
# Retrieve RECORDING's metadata.
# (Most metadata can be used exactly as it is formatted in the mythconverg database.)
declare -r RECORDED_TITLE=$( $MYSQL_CMD "SELECT title FROM recorded WHERE $MYSQL_WHERE;" )
declare -r RECORDED_SUBTITLE=$( $MYSQL_CMD  "SELECT subtitle FROM recorded WHERE $MYSQL_WHERE;" )
declare -r RECORDED_BASENAME=$( $MYSQL_CMD  "SELECT basename FROM recorded WHERE $MYSQL_WHERE;" )
declare -r RECORDED_STORAGEGROUP=$( $MYSQL_CMD  "SELECT storagegroup FROM recorded WHERE $MYSQL_WHERE;" )
declare -r RECORDED_PROGRAMID=$( $MYSQL_CMD "SELECT programid FROM recorded WHERE $MYSQL_WHERE;" )
declare -r RECORDED_ORIGINALAIRDATE=$( $MYSQL_CMD "SELECT originalairdate FROM recorded WHERE $MYSQL_WHERE;" )
#
declare -r RECORDED_DIRNAME=$( $MYSQL_CMD  "SELECT dirname FROM storagegroup WHERE groupname=\"$RECORDED_STORAGEGROUP\";" )
#
# Check whether there are any overrides for the status of commercials.
if [ -z "${CHANID_COMMERCIAL_FREE}" ]
then
	# The override list is empty so use metadata to set the status of commercials in this recording.
	declare -r RECORDED_COMMFLAGGED=$( $MYSQL_CMD "SELECT commflagged FROM recorded WHERE $MYSQL_WHERE;" )	
else
	# Check whether CHANNEL_ID is commercial-free.
	if [[ $CHANID_COMMERCIAL_FREE = *"$CHANID_SEPARATOR$CHANNEL_ID$CHANID_SEPARATOR"* ]]
	then
    	# Consider this recording to be commercial-free, "
    	declare -r RECORDED_COMMFLAGGED="$COMMFLAG_COMM_FREE_CHANNEL"
    	#
    	# Log match to list of commercial-free channels.
		if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
		then
			logIt "CHANNEL_ID is in the list of commercial-free stations."
			logVar "CHANNEL_ID"
			logVar "CHANID_COMMERCIAL_FREE"
		fi	
	else
		# Use metadata to set the status of commercials in this recording.
		declare -r RECORDED_COMMFLAGGED=$( $MYSQL_CMD "SELECT commflagged FROM recorded WHERE $MYSQL_WHERE;" )
	fi
fi
#
# Myth stores Season and Episode without leading zeros but Plex requires them to be exactly two digits long.
recordedSeason=$( $MYSQL_CMD  "SELECT season FROM recorded WHERE $MYSQL_WHERE;" )
recordedEpisode=$( $MYSQL_CMD  "SELECT episode FROM recorded WHERE $MYSQL_WHERE;" )
if [[ ${#recordedSeason} -ne 2 ]] 
then
    recordedSeason="00${recordedSeason}"
    recordedSeason="${recordedSeason: -2}"
fi
if [[ ${#recordedEpisode} -ne 2 ]] 
then
    recordedEpisode="00${recordedEpisode}"
    recordedEpisode="${recordedEpisode: -2}"
fi
#
#Extract media type from RECORDED_PROGRAMID.
declare -r MEDIA_TYPE="${RECORDED_PROGRAMID:0:2}"
#
# Extract file extension alone from RECORDED.BASENAME
declare -r RECORDED_BASENAME_EXT="${RECORDED_BASENAME#*.}"
#
# Extract file name alone from RECORDED.BASENAME
declare -r RECORDED_BASENAME_ONLY="${RECORDED_BASENAME%.*}"
#
# Log metadata retrieved from mythconverg database.
if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
then
	logVar "RECORDED_TITLE"
	logVar "RECORDED_SUBTITLE"
	logVar "RECORDED_BASENAME"
	logVar "RECORDED_STORAGEGROUP"
	logVar "RECORDED_PROGRAMID"
	logVar "RECORDED_DIRNAME"
	logVar "RECORDED_ORIGINALAIRDATE"
	logVar "RECORDED_COMMFLAGGED"
	logVar "recordedSeason"
	logVar "recordedEpisode"
	logVar "MEDIA_TYPE"
	logVar "RECORDED_BASENAME_EXT"
	logVar "RECORDED_BASENAME_ONLY"
fi
#
# Create fully qualified file names for the three RECORDINGs:
#	ORIGINAL			MythTV recording (.mpg w/ commercials)
#	COMMERCIALFREE		Transcoded (.mp2 w/o commercials)
#	H264				Transcoded (.mp4 w/o commericals)
#
#   best				Points to one of the above
logIfVerbose "Creating directory paths and file names ..."
declare -r RECORDING_ORIGINAL="$RECORDED_DIRNAME$RECORDED_BASENAME"
declare -r RECORDING_COMMERCIALFREE="$MEDIA_PATH_TMP/$RECORDED_BASENAME_ONLY.mp2"
declare -r RECORDING_H264="$RECORDED_DIRNAME$RECORDED_BASENAME_ONLY.$H264_EXTENSION"
#
# Original is the best file prior to commercial removal and transcoding. 
recordingBest=$RECORDING_ORIGINAL
#
# Log fully qualified file names for the four RECORDINGs.
if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
then
	logVar "RECORDING_ORIGINAL"
	logVar "RECORDING_COMMERCIALFREE"
	logVar "RECORDING_H264"
	logVar "recordingBest"
fi
#
# Plex settings that must be different for Movies vs. TV, i.e., based on value of RECORDED_STORAGEGROUP
#	PMS_SECTION_ID			PMS SectionID (XML used by PMS)
#	RECORDING_PMS_PATH		Path of symbolic link to best recording file
#	RECORDING_PMS_NAME_ONLY	Filename only of symbolic link to best recording file
#							(Extension may change depending on success of removing commercials and H264 encoding.)
#
logIfVerbose "Creating PMS Section ID, path, and file name ..."
case "$RECORDED_STORAGEGROUP" in
    ( "$STORAGEGROUP_MOVIE" )
    	declare -r PMS_SECTION_ID="$PMS_SECTION_ID_MOVIE"
    	makeFilenameSafe "$RECORDED_TITLE (${RECORDED_ORIGINALAIRDATE:0:4})"
    	declare -r RECORDING_PMS_PATH="$MEDIA_PATH_PMS_MOVIES/$safeFilename"
    	declare -r RECORDING_PMS_NAME_ONLY="$safeFilename"
        ;;
    ( "$STORAGEGROUP_LIVETV" | "$STORAGEGROUP_DEFAULT" )
        declare -r PMS_SECTION_ID="$PMS_SECTION_ID_TV"
        makeFilenameSafe "$RECORDED_TITLE"
    	RECORDING_PMS_PATH="$MEDIA_PATH_PMS_TV/$safeFilename/Season $recordedSeason"
        myScrap="$safeFilename - s$recordedSeason"
        myScrap+="e$recordedEpisode - "
    	#
    	# Check whether RECORDED_SUBTITLE is empty or only spaces.
		if [ -z "${RECORDED_SUBTITLE// }" ] 
		then 
			# Use the channel and time to ensure that the file name will be unique.
			# (Remove colons (":") from time for filesystem compatibility.)
			myScrap+="Recorded on $CHANNEL_ID at ${START_TIME_UTC//[:]/-}"
		else
			# Assume RECORDED_SUBTITLE makes the  file name unique. 
			makeFilenameSafe "$RECORDED_SUBTITLE"
			myScrap+="$safeFilename"
		fi
        declare -r RECORDING_PMS_NAME_ONLY="$myScrap"
        ;;
    ( * )
        logIt "Error: Recording is not in the STORAGEGROUP for either movie or tv video ..."
        logVar "RECORDED_STORAGEGROUP"
        logVar "STORAGEGROUP_MOVIE"
        logVar "STORAGEGROUP_LIVETV"
        logFail
        ;;
esac
#
# Log Plex Section ID, path, and file name.
logVarIfVerbose "PMS_SECTION_ID"
logVarIfVerbose "RECORDING_PMS_PATH"
logVarIfVerbose "RECORDING_PMS_NAME_ONLY"
#
# Check whether recording exists.
if [ ! -f "$RECORDING_ORIGINAL" ]
then
    # File named in database not found in recording directory.
	logIt "Error: File name in database not found on file system.  Check path."
	logVar "RECORDING_ORIGINAL"
	logFail
fi
#
# Log attributes of original file before any transcoding or file system changes.
logIfLogging "Original Recording: $(  eval "ls $CMD_LS_OPTIONS \"$RECORDING_ORIGINAL\""  )" 
#
# 
# Check job priority for script
scriptProcessNiActual="$(ps -p $SCRIPT_PROCESS_ID -o ni=)"
if [[ $SCRIPT_PROCESS_NI_DESIRED -gt "$scriptProcessNiActual" ]]
then
	# Script is running at a greater priority than desired.
	# Throttle CPU usage to desired level because transcoding is CPU-intensive.
	#
	# Log start of throttle and current priority. 
	logIfVerbose "CPU throttle ..."
	logIfVerbose "Before renice: $scriptProcessNiActual"
	#
	# Run renice to change CPU priority.
	cmdString="renice $SCRIPT_PROCESS_NI_DESIRED $SCRIPT_PROCESS_ID"
	cmdLogMsg="Change process priority request"
	runCmd "$cmdString" "$cmdLogMsg"
	#
	# Log new priority. 
	scriptProcessNiActual="$(ps -p $SCRIPT_PROCESS_ID -o ni=)"
	logIfVerbose "After renice: $scriptProcessNiActual"
else
		if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
		then
			logIt "No need to renice."
			logIt "Actual nice: $scriptProcessNiActual"
			logIt "Desired nice: $SCRIPT_PROCESS_NI_DESIRED"
		fi
fi
#
# Throttle input/output usage.
# (Apparently ionice isn't available on FreeNAS.)
# ionice -c 3 -p $SCRIPT_PROCESS_ID
#
#
#
# ************************************************************************
# *  Step 1
# *  Flag and remove commercials
# *
#
#
#  Check whether this is an original recording vs. one that has already been processed.
if [[ $RECORDED_BASENAME_EXT != "$ORIGINAL_EXTENSION" ]]
then
	# The recording, $RECORDING_ORIGINAL, does not have the file extension (.mpg) that MythTV uses for its recordings.  Apparently, this file has been changed, presumably by this script.
	# (Presumably it is already commercial-free and MPEG4-encoded; regardless, it is considered the best recording.)
	logIfLogging "The recording, \"$RECORDING_ORIGINAL\", has been modified.  Perhaps it is already a commercial-free MPEG4.  Regardless, commercial removal and MPEG4 encoding will be skipped."
	declare -r COMMERCIALS_FLAGGED=false
	declare -r COMMERCIALS_GENCUTLIST=false
	declare -r COMMERCIALS_TRANSCODE=false
	declare -r COMMERCIALS_MPEG4=false
else
	# Recording has the extension that MythTV uses for recordings so assume that it is the original, MPEG2-encoded file.
	# Flag commercials as neccessary.
	case "$RECORDED_COMMFLAGGED" in
		( "$COMMFLAG_PROCESSING" )
			# Commflag is already running on this file; let it finish. 
			# (Presumably the Job Queue is configured to run it.)
			logIt "Error: Commflag is still running from post-recording processing."
			logVar "RECORDED_COMMFLAGGED"
			logVar "COMMFLAG_PROCESSING"
			logFail
			;;	
		( "$COMMFLAG_DONE" )
			# Commercials already flagged.
			declare -r COMMERCIALS_FLAGGED=true
			logIfVerbose "There is no need to flag commercials because they were already flagged."
			;;
		( "$COMMFLAG_COMM_FREE_CHANNEL" )
			# No need to flag commercials
			declare -r COMMERCIALS_FLAGGED=false
			logIfVerbose "There is no need to flag commercials because this recording is from a commercial-free channel."
			;;
		( "$COMMFLAG_NOT_FLAGGED" )
			# Must run mythcommflag to flag commercials.
			cmdString="$MYTHTV_PATH/mythcommflag --chanid $CHANNEL_ID --starttime $START_TIME_UTC"
			# Check whether mythcommflag should be modified with an override file.
			if [ -n "${MYTHCOMMFLAG_OVERRIDES}" ]
			then
				# Specify the override file parameter.
				cmdString+=" --override-settings-file $MYTHCOMMFLAG_OVERRIDES "
			fi
			#
			# Set mythcommflag logging level
			if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
			then
				cmdString+=" --logpath $LOG_PATH"
				case "$LOGGING_MODE" in
					( "$LOGGING_VERBOSE" )
						cmdString+=" --loglevel info"
						;;
					( "$LOGGING_DEBUG" )
						cmdString+=" --loglevel debug"
						;;
					( "$LOGGING_MINIMAL" )
						cmdString+=" --loglevel err"
						;;
					( "$LOGGING_NONE" )
						;;
					( * )
						logIt "Error: LOGGING_MODE (\"$LOGGING_MODE\") is not valid.  Acceptable values are:"
						logVar "LOGGING_NONE"
						logVar "LOGGING_MINIMAL"
						logVar "LOGGING_VERBOSE"
						logVar "LOGGING_DEBUG"
						logFail
						;;
				esac			
			fi
			#
			# Log start of mythcommflag to flag commericals
			if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]]
			then
				logFullName="$LOG_PATH/mythcommflag.nowUTC.pid.log"
				logIt "Starting mythcommflag ..."
				logIt "Log at $logFullName; nowUTC ~ $(nowUTC) and PID=\"$SCRIPT_PROCESS_ID\""				
			fi
			#
			# Run mythcommflag and check return code.			
			cmdLogMsg="mythcommflag attempt to flag commericals in \"$RECORDING_ORIGINAL\""
			runCmd "$cmdString" "$cmdLogMsg"
			cmdReturnCode=$?
			#
			# Check whether mythcommflag exited with an error.
			if [ $cmdReturnCode -gt "$ERROR_CODE_THRESHOLD_COMMFLAG" ]
			then
				# Save and log failure.
				declare -r COMMERCIALS_FLAGGED=false
			else
				# Save and log success.
				declare -r COMMERCIALS_FLAGGED=true
				#
				# Check whether any commercials were found.
				if [ $cmdReturnCode -le $ERROR_CODE_THRESHOLD_COMMFLAG ]
				then
					logIfLogging "Number of commercials flagged: $cmdReturnCode"
				fi
				#
				# Update database value of RECORDED_COMMFLAGGED.
				$( $MYSQL_CMD "UPDATE recorded SET commflagged=\"$COMMFLAG_DONE\" WHERE $MYSQL_WHERE;" )
# 				cmdString="$MYSQL_CMD UPDATE recorded SET commflagged=\"$COMMFLAG_DONE\" WHERE $MYSQL_WHERE;"
# 				cmdLogMsg="Update status of commflagged"
# 				runCmd "$cmdString" "$cmdLogMsg"
# 				cmdReturnCode=$?
# 				#
# 				if [[ $cmdReturnCode -gt "$ERROR_CODE_THRESHOLD_MYSQL"  ]]
# 				then
# 					logFail
# 				fi
				
				
			fi
			;;
		( * )
			logIt "Error: Commflag value can not be interpreted ..."
			logVar "RECORDED_COMMFLAGGED"
			logVar "COMMFLAG_NOT_FLAGGED"
			logVar "COMMFLAG_DONE"
			logVar "COMMFLAG_PROCESSING"
			logVar "COMMFLAG_COMM_FREE_CHANNEL"
			logFail
			;;
	esac
	#
	#  Check whether commercials are flagged.
	if $COMMERCIALS_FLAGGED 
	then 
		# Move flagged commercials into a cut list.
		# (Used to be done in mythcommflag but now done in mythutil.)
		cmdString="$MYTHTV_PATH/mythutil --chanid $CHANNEL_ID --starttime $START_TIME_UTC --gencutlist"
		#
		# Set mythutil logging level
		if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
		then
			cmdString+=" --logpath $LOG_PATH"
			case "$LOGGING_MODE" in
				( "$LOGGING_VERBOSE" )
					cmdString+=" --loglevel info"
					;;
				( "$LOGGING_DEBUG" )
					cmdString+=" --loglevel debug"
					;;
				( "$LOGGING_MINIMAL" )
					cmdString+=" --loglevel err"
					;;
				( "$LOGGING_NONE" )
					;;
				( * )
					logIt "Error: LOGGING_MODE (\"$LOGGING_MODE\") is not valid.  Acceptable values are:"
					logVar "LOGGING_NONE"
					logVar "LOGGING_MINIMAL"
					logVar "LOGGING_VERBOSE"
					logVar "LOGGING_DEBUG"
					logFail
					;;
			esac
		fi
		#
		# Log start of generating cut list.
		if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
		then
			logFullName="$LOG_PATH/mythutil.nowUTC.pid.log"
			logIt "Starting mythutil to generate list of commercials to cut... "
			logIt "Log at $logFullName; nowUTC ~ $(nowUTC) and PID=\"$SCRIPT_PROCESS_ID\"" 
		fi	
		#
		# Run mythutil to generate cutlist and check return code.
		cmdLogMsg="mythutil generating cutlist"
		runCmd "$cmdString" "$cmdLogMsg"
		cmdReturnCode=$?
		if [[ $cmdReturnCode -ne "$ERROR_CODE_THRESHOLD_NORMAL" ]]
		then
			declare -r COMMERCIALS_GENCUTLIST=false
		else
			declare -r COMMERCIALS_GENCUTLIST=true
		fi
	else
		declare -r COMMERCIALS_GENCUTLIST=false		
	fi
	#
	#  Check whether cutlist was generated.
	if $COMMERCIALS_GENCUTLIST
	then 
		# Transcode original recording to new MPEG2 file without commercials.
		# (Lossless MPEG2 -> MPEG2 transcode)
		cmdString="$MYTHTV_PATH/mythtranscode --chanid $CHANNEL_ID --starttime $START_TIME_UTC --mpeg2 --honorcutlist --outfile $RECORDING_COMMERCIALFREE"
		#
		# Set mythtranscode logging level
		if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
			then
			cmdString+=" --logpath $LOG_PATH"
			case "$LOGGING_MODE" in
				( "$LOGGING_VERBOSE" )
					cmdString+=" --loglevel info"
					;;
				( "$LOGGING_DEBUG" )
					cmdString+=" --loglevel debug"
					;;
				( "$LOGGING_MINIMAL" )
					cmdString+=" --loglevel err"
					;;
				( "$LOGGING_NONE" )
					;;
				( * )
					logIt "Error: LOGGING_MODE (\"$LOGGING_MODE\") is not valid.  Acceptable values are:"
					logVar "LOGGING_NONE"
					logVar "LOGGING_MINIMAL"
					logVar "LOGGING_VERBOSE"
					logVar "LOGGING_DEBUG"
					logFail
					;;
			esac
		fi
		#
		# Log start of transcoding commercial-free MPEG2.
		if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
		then
			logFullName="$LOG_PATH/mythtranscode.nowUTC.pid.log"
			logIt "Starting mythtranscode to cut out commercials... "
			logIt "Log at $logFullName; nowUTC ~ $(nowUTC) and PID=\"$SCRIPT_PROCESS_ID\"" 	
		fi
		#
		# Run transcode to create commercial-free mp2 and check return code.
		cmdLogMsg="Transcoding commercial-free version of $RECORDING_ORIGINAL"
		runCmd "$cmdString" "$cmdLogMsg"
		cmdReturnCode=$?
		if [[ $cmdReturnCode -ne "$ERROR_CODE_THRESHOLD_NORMAL"  ]]
		then
			# Save and log mythtranscode failure.
			declare -r COMMERCIALS_TRANSCODE=false
		else
			# Save and log mythtranscode success.
			declare -r COMMERCIALS_TRANSCODE=true
			logIfLogging "Commercial-free MPEG2: $(  eval ls $CMD_LS_OPTIONS \"$RECORDING_COMMERCIALFREE\" )" 
			#
			# Commercial-free MPEG2 is now the best recording. 	
			recordingBest=$RECORDING_COMMERCIALFREE
		fi
	else
		declare -r COMMERCIALS_TRANSCODE=false		
	fi
	#
	#
	# ************************************************************************
	# *  Step 2
	# *  Transcode commercial-free MPEG2 recording to H.264 (also known as 
	# *  MPEG-4 Part 10, Advanced Video Coding (MPEG-4 AVC) )
	# *
	#
	#
	#
	# Check whether a commercial-free MPEG2 exits.
	if $COMMERCIALS_TRANSCODE
	then
		# Use commercial-free MPEG2 as input
		declare -r H264_INPUT=$RECORDING_COMMERCIALFREE
	else
		# Use original file (with commercials unless from a commercial-free station) as input
		declare -r H264_INPUT=$RECORDING_ORIGINAL
	fi
	#
	# Use HandBrakeCLI to make best-available recording H264-encoded.
	cmdString="$MYTHTV_PATH/HandBrakeCLI --input $H264_INPUT --output $RECORDING_H264 --audio 1 --aencoder copy:aac --audio-fallback faac --audio-copy-mask aac --preset=\"High Profile\""
	# 
	# Set HandBrakeCLI logging level
	if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
		then
		#  Set log location
		logFullName="$LOG_PATH/HandBrakeCLI.$START_TIME_UTC.$CHANNEL_ID.log"
		case "$LOGGING_MODE" in
			( "$LOGGING_VERBOSE" | "$LOGGING_DEBUG" )
				cmdString+=" -v2"
				logIt "Starting HandBrakeCLI to transcode $H264_INPUT -> $RECORDING_H264 ..."
				logIt "Log at $logFullName" 
				;;
			( "$LOGGING_MINIMAL" )
				cmdString+=" -v1"
				;;
			( "$LOGGING_NONE" )
				;;
			( * )
				logIt "Error: LOGGING_MODE (\"$LOGGING_MODE\") is not valid.  Acceptable values are:"
				logVar "LOGGING_NONE"
				logVar "LOGGING_MINIMAL"
				logVar "LOGGING_VERBOSE"
				logVar "LOGGING_DEBUG"
				logFail
				;;
		esac
		cmdString+=" 2> $logFullName"
	fi
	#
	# Log start of transcoding to mp4. 
	logIfVerbose "Transcode mpg/mp2 -> mp4 ..."
	#
	# Run transcode of mpg/mp2 -> mp4 and check return code.
	cmdLogMsg="HandBrakeCLI transcode $H264_INPUT -> $RECORDING_H264"
	runCmd "$cmdString" "$cmdLogMsg"
	cmdReturnCode=$?
	if [[ $cmdReturnCode -ne "$ERROR_CODE_THRESHOLD_NORMAL" ]]
	then
		# Save and log HandBrakeCLI failure.
		declare -r COMMERCIALS_MPEG4=false
	else
		#
		# Log mythtranscode exited cleanly. 
		# HandBrakeCLI exited cleanly. 
		# This does NOT indicate a complete or error-free encode. 
		# It only indicates that HandBrakeCLI has exited cleanly and that the file was properly muxed. 
		# CTRL-C will cause HandBrakeCLI to exit cleanly.
		declare -r COMMERCIALS_MPEG4=true
		logIfLogging "H264 Recording: $( eval ls $CMD_LS_OPTIONS \"$RECORDING_H264\")"
		#
		# Check whether commercials are included in MPEG4 file.
		if [[ ! $COMMERCIALS_TRANSCODE && "$RECORDED_COMMFLAGGED" -ne "$COMMFLAG_COMM_FREE_CHANNEL" ]]
		then
			# H264 recording contains commercials.
			logIfLogging "Commercials were not removed; they are in the MPEG4."	
		fi		
		#
		# H264-encoded file is now the best recording.
		recordingBest=$RECORDING_H264
	fi
fi
#
# Update file system so that all recordings are in same directory as original recording.
if [[ $recordingBest = "$RECORDING_COMMERCIALFREE" ]] 
then
	# Move commercial-free MPEG2.
	# (Original and H264 are already in the right place.)
	mv "$recordingBest" "$RECORDED_DIRNAME"
fi
#
# Check whether original recording is still the best recording. 
if [[ $recordingBest != "$RECORDING_ORIGINAL" ]]
then
	# Original recording is no longer the best recording.
	# Log best recording.
	logIfLogging "Best Recording: $( eval ls $CMD_LS_OPTIONS \"$recordingBest\" )" 
	#
	# Set ownership of best recording file to mythtv user and group. 
	chownMythtv "$recordingBest"
	#
	# Update database metadata, etc., to correspond to the best recording.
	# Get name and size of best recording.
	declare -r RECORDING_BEST_NAME="${recordingBest##*/}"
	tmpVar=$( wc -c < "$recordingBest" )
	declare -r RECORDING_BEST_SIZE="${tmpVar##* }"
	#
	# Update metadata in database.
	if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
	then
		# Log database updates.
		logIt "Updating database ..."
		logIt "recorded.basename=\"$RECORDING_BEST_NAME\""
		logIt "recorded.filesize=\"$RECORDING_BEST_SIZE\""
		logIt "recorded.transcoded=\"$DB_TINYINT_YES\""
	fi
	$( $MYSQL_CMD "UPDATE recorded SET basename=\"$RECORDING_BEST_NAME\",filesize=\"$RECORDING_BEST_SIZE\",transcoded=\"$DB_TINYINT_YES\" WHERE $MYSQL_WHERE;" )
	#
	# Fix seeking by pruning previous bookmarks from database.
	$( $MYSQL_CMD "DELETE FROM recordedmarkup WHERE $MYSQL_WHERE ;" )
	#
	# Also delete corresponding rows in related tables to prune bookmarks. Inspired from examples:
	# https://gist.github.com/kd7lxl/1449482
	# https://forums.plex.tv/discussion/141863/
	$( $MYSQL_CMD "DELETE FROM recordedseek WHERE $MYSQL_WHERE ;" )
	#
	# Original recording is now orphaned.
	# (Database no longer points to it.)
	#
	# Log start of deleting original recording. 
	logIfVerbose "Deleting original recording \"$RECORDING_ORIGINAL\" ..."
	#
	# Run rm to delete original recording.
	cmdString="rm \"$RECORDING_ORIGINAL\""
	cmdLogMsg="Delete original recording"
	runCmd "$cmdString" "$cmdLogMsg"
	# 		
	# Rename .png files so they are associated with best recording.
	# (These files are introductory shots of the recording.)
	declare -r RECORDING_BEST_EXT="${RECORDING_BEST_NAME##*.}"
	logIfVerbose "Renaming introductory shots ..."	
	for oldName in $RECORDING_ORIGINAL*.png; do
		newName="${oldName//.$ORIGINAL_EXTENSION/.$RECORDING_BEST_EXT}"
		logIfLogging "Renaming $oldName -> $newName"
		mv "$oldName" "$newName"
	done
	logIfVerbose "Renaming complete."	
fi

	
	
		
		
# 		Apparently mythcommflag can't build the recordingseek table for .mp4 files.
# 		
# 		Figure out the circumstances under which it should be rebuilt for .mpg files.
# 		
# 		
# 		Rebuild recordingseek table for best recording.
# 		cmdString="$MYTHTV_PATH/mythcommflag --chanid $CHANNEL_ID --starttime $START_TIME_UTC --rebuild "
# 		
# 		Set mythcommflag logging level
# 		if [[ $LOGGING_MODE -gt "$LOGGING_NONE" ]] 
# 		then
# 			cmdString+=" --logpath $LOG_PATH"
# 			case "$LOGGING_MODE" in
# 				( "$LOGGING_VERBOSE" )
# 					cmdString+=" --loglevel info"
# 					;;
# 				( "$LOGGING_DEBUG" )
# 					cmdString+=" --loglevel debug"
# 					;;
# 				( "$LOGGING_MINIMAL" )
# 					cmdString+=" --loglevel err"
# 					;;
# 				( "$LOGGING_NONE" )
# 					;;
# 				( * )
# 					logIt "Error: LOGGING_MODE (\"$LOGGING_MODE\") is not valid.  Acceptable values are:"
# 					logVar "LOGGING_NONE"
# 					logVar "LOGGING_MINIMAL"
# 					logVar "LOGGING_VERBOSE"
# 					logVar "LOGGING_DEBUG"
# 					logFail
# 					;;
# 			esac			
# 		fi
# 		
# 		Log start of rebuild. 
#  		logIfVerbose "Starting mythcommflag... "
#		logIfVerbose "(Log at $LOG_PATH/mythcommflag.nowUTC.pid.log; nowUTC ~ $(nowUTC) and PID=\"$SCRIPT_PROCESS_ID\")" 	
# 		logIfLogging "$cmdString"
# 		
# 		Run mythcommflag to rebuild recordingseek table.
# 		$cmdString
# 		cmdReturnCode=$?
# 		
# 		Check whether mythcommflag exited with an error.
# 		if [ $cmdReturnCode -ne 0 ]
# 		then
# 			Log mythcommflag failure to rebuild recordingseek table.
# 			if [[ $LOGGING_MODE -ge "$LOGGING_NONE" ]] 
# 			then
# 				logIt "Error: mythcommflag failed while rebuilding seek table."
# 				logVar "CHANNEL_ID" 
# 				logVar "START_TIME_UTC"
# 				logIt "Error: \"$cmdReturnCode\""
# 			fi
# 		else
# 			Log mythcommflag success.
# 			logIfLogging "mythcommflag successfully rebuilt seektable."
# 		fi
		
		
		

#
# Delete intermediate files, if any.
if [ -f "$RECORDING_COMMERCIALFREE" ]
then
		# Log start of deleting commerical-free intermediate file. 
		logIfVerbose "Deleting commerical-free intermediate file \"$RECORDING_COMMERCIALFREE\" ..."
		#
		# Run rm to delete intermediate recording.
		cmdString="rm \"$RECORDING_COMMERCIALFREE\""
		cmdLogMsg="Delete commercial-free intermediate recording"
		runCmd "$cmdString" "$cmdLogMsg"
fi 
if [ -f "$RECORDING_COMMERCIALFREE.map" ]
then 
		# Log start of deleting commerical-free intermediate map file. 
		logIfVerbose "Deleting commerical-free intermediate map file \"$RECORDING_COMMERCIALFREE.map\" ..."
		#
		# Run rm to delete intermediate map file.
		cmdString="rm \"$RECORDING_COMMERCIALFREE.map\""
		cmdLogMsg="Delete commercial-free intermediate map file"
		runCmd "$cmdString" "$cmdLogMsg"
fi 
#
#
# ************************************************************************
# *  Step 4
# *  Create/Maintain PMS symbolic link to the best recording.
# *
#
# 
# Get basename of recording from database.
#declare -r PMS_BASENAME=$( $MYSQL_CMD  "SELECT basename FROM recorded WHERE $MYSQL_WHERE;" )
declare -r PMS_BASENAME="$RECORDING_BEST_NAME"
declare -r PMS_BASENAME_EXT="${PMS_BASENAME#*.}"
declare -r PMS_LINK_PATH_AND_NAME="$RECORDING_PMS_PATH/$RECORDING_PMS_NAME_ONLY.$PMS_BASENAME_EXT"
if [[ $LOGGING_MODE -ge "$LOGGING_VERBOSE" ]] 
then
	logVar "PMS_BASENAME"
	logVar "PMS_BASENAME_EXT"
	logVar "PMS_LINK_PATH_AND_NAME"
fi

#
# Create directory in PMS library, if it doesn't exist already.
logIfVerbose "Creating directory in PMS library (if it doesn't exist already)."
cmdString="mkdir -p \"$RECORDING_PMS_PATH\""
cmdLogMsg="Create directory in PMS library"
runCmd "$cmdString" "$cmdLogMsg"
logIfVerbose "PMS Directory: $(  eval ls $CMD_LS_OPTIONS \"$RECORDING_PMS_PATH\" )" 
#
# Create symbolic link (symlink) in PMS Library to (best) recording in Plex directory.
# (Link name uses format required by PMS.)
# Check whether a file with name already exists.
if [ -e "$PMS_LINK_PATH_AND_NAME" ] 
then
	# Filename already exists.
	# Log unexpected presence of file.
	logIt "Warning: File or symbolic link already exists in PMS Library."
	logVar "PMS_LINK_PATH_AND_NAME"
	logIt "PMS Link: $( eval ls $CMD_LS_OPTIONS \"$PMS_LINK_PATH_AND_NAME\" )"
	#
	# Check whether file is a symbolic Link
	if [ -L "$PMS_LINK_PATH_AND_NAME" ]
	then
		# Unexpected file is a symbolic link.
		# Get the full path of symlink target.
		myScrap=$( readlink -f "$PMS_LINK_PATH_AND_NAME" )
		# Check whether myScrap is either empty or all spaces.
		if [ -n "${myScrap// }" ] 
		then
			# Check symlink target.
			if [ -e "$myScrap" ] && [ "$myScrap" != "$RECORDED_DIRNAME$PMS_BASENAME" ]
			then
				# Target exists and is NOT the best recording.
				# Delete target file (since it will be orphaned after the symlink is deleted below).
				cmdString="rm \"$myScrap\""
				cmdLogMsg="Delete symlink target $myScrap"
				runCmd "$cmdString" "$cmdLogMsg"
			fi
		fi
	fi 
	#
	# Delete unexpected file.
	cmdString="rm \"$PMS_LINK_PATH_AND_NAME\""
	cmdLogMsg="Delete unexpected file $PMS_LINK_PATH_AND_NAME"
	runCmd "$cmdString" "$cmdLogMsg"
fi
# Make PMS_LINK_PATH_AND_NAME a symbolic link to (best) recording in MythTV directory.
# Log start of creating symlink.
logIfVerbose "Creating symbolic link in PMS library to (best) recording in MythTV directory ..."
#
# Run ln to create symlink.
cmdString="ln -s \"$RECORDED_DIRNAME$RECORDING_BEST_NAME\" \"$PMS_LINK_PATH_AND_NAME\""
cmdLogMsg="Create symlink in PMS library"
runCmd "$cmdString" "$cmdLogMsg"
#
# Set ownership of this new PMS file to mythtv user and group. 
logIfVerbose "Setting link's ownership to: \"$FILE_OWNER:$FILE_GROUP\" ..."
chownMythtv "$PMS_LINK_PATH_AND_NAME"
#
# Log symbolic link
logIfLogging "PMS Link: $( eval ls $CMD_LS_OPTIONS \"$PMS_LINK_PATH_AND_NAME\" )"

#
# Prune all PMS symbolic links that point to files that no longer exist.
# (Broken as a result of MythTV's auto expire, manually deleted, etc.)
logIfVerbose "Pruning PMS Library links to files that no longer exist in Plex directory ..."
find "$MEDIA_PATH_PMS" -type l | while read -r f; do 
	if [ ! -e "$f" ]
	then
		# Even though it was just created, -e thinks that PMS_LINK_PATH_AND_NAME doesn't exist.
		if [[ $f != "$PMS_LINK_PATH_AND_NAME" ]]
		then
			cmdString="rm -f \"$f\""
			cmdLogMsg="Delete symlink \"$f\""
			runCmd "$cmdString" "$cmdLogMsg"
		fi
	fi
done
logIfVerbose "Pruning PMS Links complete."
#
# Prune empty PMS folders
# Log start of pruning.
logIfVerbose "Pruning empty directories in PMS Library ..."
#
# find empty PMS Library directories and delete them.
find  "$MEDIA_PATH_PMS" -type d -empty | while read -r d ; do
	cmdString="rm -fr \"$d\""
	cmdLogMsg="Delete directory \"$d\""
	runCmd "$cmdString" "$cmdLogMsg"
done
logIfVerbose "Pruning PMS Directories complete."
#
# Request via  HTTP interface that Plex Update its Library.
# Example:http://10.10.49.14:32400/library/sections/04/refresh?force=1
# Log start of PMS Library Update. 
logIfVerbose "Updating PMS Library ..."
cmdString="curl -f $PMS_URL/library/sections/$PMS_SECTION_ID/refresh?force=1" 
cmdLogMsg="Sending PMS Library Update request"
runCmd "$cmdString" "$cmdLogMsg"
#
#
# ************************************************************************
# *  Step 5
# *  Delete old log files.
# *
#
# Check to see whether logs should be automatically deleted.
# (Must be an unsigned integer.)
if [[ $LOG_DAYS_TO_KEEP =~ ^[0-9]+$ ]]
then
	# 
	# Initialize variables.
	declare -r SECONDS_PER_DAY="86400"  # 60 sec/min x 60 min/hr  x 24 hr/day = 86400 sec/day
	declare -r LOG_SECONDS_TO_KEEP=$(( LOG_DAYS_TO_KEEP * SECONDS_PER_DAY ))
	declare -r SECONDS_SINCE_EPOCH="$(date +%s)"
	#
	# Prune old log files.
	logIfVerbose "Pruning log files older than $LOG_DAYS_TO_KEEP days old ..."
	#
	# Loop through all files in the log directory.
	# (Includes log files written by other scripts and executables.)
	for logFile in $LOG_PATH/*.$LOG_EXT; do
		#
		# File's age is the difference between now and its creation date.
		# logFileCreatedSecondsSinceEpoch="$( stat --format=%W \"$logFile\" )"
		# (stat doesn't have a POSIX standard for time created since epoch.)
		# (for FreeBSD: stat -f%B $logFile
		# (Modify stat for your platform as necessary.)
		logFileCreatedSecondsSinceEpoch=$(stat -f%B $logFile)
		logFileAge="$(( SECONDS_SINCE_EPOCH - logFileCreatedSecondsSinceEpoch ))"
		#
		# Check whether file's age is more than LOG_DAYS_TO_KEEP.
		if [[ $logFileAge -gt "$LOG_SECONDS_TO_KEEP" ]]
		then
			# Delete logFile
			cmdString="rm \"$logFile\""
			# cmdString="ls $CMD_LS_OPTIONS \"$logFile\""
			cmdLogMsg="Delete $logFile"
			runCmd "$cmdString" "$cmdLogMsg"
		fi
	done
	logIfVerbose "Pruning Log files complete."
fi
#
#
# ************************************************************************
# *  Step 6
# *  Normal exit.
# *
#
logIfLogging "Exiting normally."
#
#
# Check whether to email log file.
if [[ $EMAIL_LOG_MODE = "$EMAIL_LOG_ALWAYS" ]]
then
	# Mail log file to root.
	logMsg  "$SCRIPT_NAME Exited Normally"
	queueLogForEmail
fi
exit 0