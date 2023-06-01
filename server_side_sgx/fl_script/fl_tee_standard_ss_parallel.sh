#!/bin/bash
set -e
. /opt/openenclave/share/openenclave/openenclaverc

IP_CLIENT_LIST=("127.0.0.1" "127.0.0.1")
PORT_CLIENT_LIST=(7777 8888)
PASSWORD_CLIENT_LIST=("root" "root")

NUM_ROUNDS=2
NUM_CLIENTS=2

PP_START=6
PP_END=8

DATASET=mnist
MODEL=lenet

SERVER_APP_DIR="/home/hh2119/workspace/PPFL/server_side_sgx/"
SERVER_AVERAGED_DIR="./results/${DATASET}/averaged_standard_ss/"
SERVER_UPDATES_DIR="./results/${DATASET}/client_updates_standard_ss/"
CLIENT_MODEL_DIR="/root/models/${DATASET}/"
CLIENT_BACKUP_DIR="/root/tmp/backup/"
DM="${DATASET}_${MODEL}"

STARTER_REE="./results/${DATASET}/${DM}_pp${PP_START}${PP_END}.weights_ree"
STARTER_TEE="./results/${DATASET}/${DM}_pp${PP_START}${PP_END}.weights_tee"


echo "============= initialization ============="
cd ${SERVER_APP_DIR}

rm -rf ${SERVER_UPDATES_DIR}
mkdir ${SERVER_UPDATES_DIR}

rm -rf ${SERVER_AVERAGED_DIR}
mkdir ${SERVER_AVERAGED_DIR}

cp ${STARTER_REE} "${SERVER_AVERAGED_DIR}${DM}_averaged_r0.weights_ree"
cp ${STARTER_TEE} "${SERVER_AVERAGED_DIR}${DM}_averaged_r0.weights_tee"
for ((c=1;c<=NUM_CLIENTS;c++))
do
	cp=$((c-1))
	ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "[${IP_CLIENT_LIST[${cp}]}]:${PORT_CLIENT_LIST[${cp}]}"
	sshpass -p ${PASSWORD_CLIENT_LIST[${cp}]} scp -o StrictHostKeyChecking=accept-new -P ${PORT_CLIENT_LIST[${cp}]} "cfg/${DM}.cfg" "root@${IP_CLIENT_LIST[${cp}]}:cfg/${DM}.cfg"
done

for ((r=1;r<=NUM_ROUNDS;r++))
do
	echo "============= round ${r} ============="
	for ((c=1;c<=NUM_CLIENTS;c++))
	do
		echo "============= copy weights server -> client ${c} ============="
		rp=$((r-1))
		cp=$((c-1))
		time sshpass -p ${PASSWORD_CLIENT_LIST[${cp}]} scp -P ${PORT_CLIENT_LIST[${cp}]} "${SERVER_AVERAGED_DIR}${DM}_averaged_r${rp}.weights_ree" "root@${IP_CLIENT_LIST[${cp}]}:${CLIENT_MODEL_DIR}${DM}_global.weights_ree"
		filesize=$(stat --format=%s "${SERVER_AVERAGED_DIR}${DM}_averaged_r${rp}.weights_ree")
		echo "ree weights: ${filesize} Bytes"
		sleep 3s
		
		time sshpass -p ${PASSWORD_CLIENT_LIST[${cp}]} scp -P ${PORT_CLIENT_LIST[${cp}]} "${SERVER_AVERAGED_DIR}${DM}_averaged_r${rp}.weights_tee" "root@${IP_CLIENT_LIST[${cp}]}:${CLIENT_MODEL_DIR}${DM}_global.weights_tee"
		filesize=$(stat --format=%s "${SERVER_AVERAGED_DIR}${DM}_averaged_r${rp}.weights_tee")
		echo "tee weights: ${filesize} Bytes"
		sleep 3s
	done
	# run processes and store pids in array
	for ((c=1;c<=NUM_CLIENTS;c++))
	do
		echo "============= ssh to the client ${c} and local training ============="
		cp=$((c-1))
		# training with TEEs (for ss, only support tee)
		time sshpass -p ${PASSWORD_CLIENT_LIST[${cp}]} ssh -o StrictHostKeyChecking=accept-new -p ${PORT_CLIENT_LIST[${cp}]} "root@${IP_CLIENT_LIST[${cp}]}" \
			darknetp classifier train -pp_start ${PP_START} -pp_end ${PP_END} -ss 1 "cfg/${DATASET}.dataset" "cfg/${DM}.cfg" "${CLIENT_MODEL_DIR}${DM}_global.weights" \
			1> >(sed "s/^/[c${c}] /") 2> >(sed "s/^/[c${c}] /" >&2) &
		pids[${cp}]=$!
		sleep 3s
	done
	# wait for all pids
	for pid in ${pids[*]}; do
		wait $pid
	done
	for ((c=1;c<=NUM_CLIENTS;c++))
	do
		echo "============= copy weights client ${c} -> server ============="
		cp=$((c-1))
		rm -rf "${SERVER_UPDATES_DIR}${DM}_c${c}.weights"
		mkdir "${SERVER_UPDATES_DIR}${DM}_c${c}.weights"
		time sshpass -p ${PASSWORD_CLIENT_LIST[${cp}]} scp -P ${PORT_CLIENT_LIST[${cp}]} "root@${IP_CLIENT_LIST[${cp}]}:${CLIENT_BACKUP_DIR}${DM}.weights_ree" "${SERVER_UPDATES_DIR}${DM}_c${c}.weights/_ree"
		filesize=$(stat --format=%s "${SERVER_UPDATES_DIR}${DM}_c${c}.weights/_ree")
		echo "ree weights: ${filesize} Bytes"
		sleep 3s
		
		time sshpass -p ${PASSWORD_CLIENT_LIST[${cp}]} scp -P ${PORT_CLIENT_LIST[${cp}]} "root@${IP_CLIENT_LIST[${cp}]}:${CLIENT_BACKUP_DIR}${DM}.weights_tee" "${SERVER_UPDATES_DIR}${DM}_c${c}.weights/_tee"
		filesize=$(stat --format=%s "${SERVER_UPDATES_DIR}${DM}_c${c}.weights/_tee")
		echo "tee weights: ${filesize} Bytes"
		sleep 3s
	done

	echo "============= averaging ============="
	time host/secure_aggregation_host server model_aggregation -pp_start ${PP_START} -pp_end ${PP_END} -ss 1 "cfg/${DM}.cfg" ${SERVER_UPDATES_DIR}
	mv "${SERVER_UPDATES_DIR}${DM}_averaged.weights_ree" "${SERVER_AVERAGED_DIR}${DM}_averaged_r${r}.weights_ree"
	mv "${SERVER_UPDATES_DIR}${DM}_averaged.weights_tee" "${SERVER_AVERAGED_DIR}${DM}_averaged_r${r}.weights_tee"
done
