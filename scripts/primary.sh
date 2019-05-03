#!/bin/bash

replSetName=$1
secondaryNodes=$2
mongoAdminUser=$3
mongoAdminPasswd=$4
staticIp=$5
location=$6
adminPassword=$7
adminUsername=$8

platformAddress="cloudapp.azure.com"

install_dependencies() {

	#create repo
	apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 9DA31620334BD75D9DCB49F368818C72E52529D4
	echo "deb [ arch=amd64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.0.list
	
	apt-get update
	
	#install
	apt-get install -y mongodb-org

	#configure
	#sed -i 's/\(bindIp\)/#\1/' /etc/mongod.conf

	#install sshpass
	sudo apt install sshpass
}

disk_format() {
	cd /tmp

	for ((j=1;j<=3;j++))
	do
		wget https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/shared_scripts/ubuntu/vm-disk-utils-0.1.sh 
		if [[ -f /tmp/vm-disk-utils-0.1.sh ]]; then
			bash /tmp/vm-disk-utils-0.1.sh -b /var/lib/mongo -s
			if [[ $? -eq 0 ]]; then
				sed -i 's/disk1//' /etc/fstab
				umount /var/lib/mongo/disk1
				mount /dev/md0 /var/lib/mongo
			fi
			break
		else
			echo "download vm-disk-utils-0.1.sh failed. try again."
			continue
		fi
	done
		
}

install_dependencies
disk_format

#start mongod
mongod --bind_ip 0.0.0.0 -v --dbpath /var/lib/mongo/ --logpath /var/log/mongodb/mongod.log --fork

sleep 30
ps -ef |grep "mongod" | grep -v grep
n=$(ps -ef |grep "mongod" | grep -v grep |wc -l)
echo "the number of mongod process is: $n"
if [[ $n -eq 1 ]];then
    echo "mongod started successfully"
else
    echo "Error: The number of mongod processes is 2+ or mongod failed to start because of the db path issue!"
fi

#create users
mongo <<EOF
use admin
db.createUser({user:"$mongoAdminUser",pwd:"$mongoAdminPasswd",roles:[{role: "userAdminAnyDatabase", db: "admin" },{role: "readWriteAnyDatabase", db: "admin" },{role: "root", db: "admin" }]})
exit
EOF
if [[ $? -eq 0 ]];then
    echo "mongo user added succeefully."
else
    echo "mongo user added failed!"
fi

#stop mongod
sleep 15
echo "the running mongo process id is below:"
ps -ef |grep mongod | grep -v grep |awk '{print $2}'
MongoPid=`ps -ef |grep mongod | grep -v grep |awk '{print $2}'`
echo "MongoPid is: $MongoPid"
kill -2 $MongoPid

sleep 15
MongoPid1=`ps -ef |grep mongod | grep -v grep |awk '{print $2}'`
if [[ -z $MongoPid1 ]];then
    echo "shutdown mongod successfully"
else
    echo "shutdown mongod failed!"
    kill $MongoPid1
    sleep 15
fi

#set keyFile
sudo chmod -R 777 /var/lib/mongo
sudo openssl rand -base64 756 > /var/lib/mongo/keyfile
sudo chmod 400 /var/lib/mongo/keyfile
sudo chown mongodb:mongodb /var/lib/mongo/keyfile

#restart primary node with auth and replica set
echo "start primary mongo node"
sudo mongod --bind_ip 0.0.0.0 -v --auth --keyFile /var/lib/mongo/keyfile --dbpath /var/lib/mongo/ --replSet $replSetName --logpath /var/log/mongodb/mongod.log --fork
echo "started primary mongo node"

#replica set initiate
echo "start replica set initiation"
mongo<<EOF
use admin
db.auth("$mongoAdminUser", "$mongoAdminPasswd")
config ={_id:"$replSetName",members:[{_id:0,host:"${replSetName}.${location}.${platformAddress}:27017"}]}
rs.initiate(config)
rs.status()
exit
EOF
if [[ $? -eq 0 ]];then
    echo "replica set initiation succeeded."
else
    echo "replica set initiation failed!"
fi

#transfer to secondary VMs and restart mongo nodes
for((i=1;i<=$secondaryNodes;i++))
do
let secondaryHostNumber=3+$i
secondaryHost="10.0.1.${secondaryHostNumber}"
echo "transfer keyfile to $secondaryHost"
sudo sshpass -p "$adminPassword" scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no /var/lib/mongo/keyfile ${adminUsername}@${secondaryHost}:/var/lib/mongo/keyfile
echo "trying to connect to secondary node $secondaryHost"
sshpass -p "$adminPassword" ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no ${adminUsername}@${secondaryHost}<<EOF
sudo mongod --bind_ip 0.0.0.0 -v --auth --keyFile /var/lib/mongo/keyfile --dbpath /var/lib/mongo/ --replSet $replSetName --logpath /var/log/mongodb/mongod.log --fork
exit
EOF
echo "exited from secondary node $secondaryHost"
done

# #Initiate replica set with 1 arbiter and 1 secondary node
echo "Replica set: add members and arbiter"
hostName="$location.$platformAddress"
echo "hostName is: $hostName"
mongo<<EOF
use admin
db.auth("$mongoAdminUser", "$mongoAdminPasswd")
for (var i = 0; i <= $secondaryNodes-1; i++) { rs.add({ host: "${replSetName}secondary" + (i-1) +".${location}.${platformAddress}:27017", _id: i, votes: 1, priority: 1 }) }
rs.addArb("${replSetName}secondary" + ($secondaryNodes-1) + ".${location}.${platformAddress}:27017")
rs.status()
exit
EOF
echo "replica set initiation finished."
