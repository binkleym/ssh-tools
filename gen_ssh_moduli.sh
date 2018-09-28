#!/usr/bin/env bash

######################################################################
##
## gen_ssh_moduli.sh - by <Mathew.Binkley@Vanderbilt.edu>
##
## This script generates a new OpenSSH moduli file suitable for
## replacing /etc/ssh/moduli.   The moduli file by default is shared
## across all distros (ie, all OpenSSH 7.5 installs on Ubuntu Bionic
## come with the same moduli file).   This gives strong incentive to
## state-level actors to attempt to compromise those particular
## primes.  We can give ourselves an additional security margin by
## replacing the stock moduli file with one we created.
######################################################################

######################################################################
## Min_Bitsize is the size in bits of the smallest DH modulus you want
## to generate.  It should be a minumum of 3072 to ensure that your
## keys have 128-bit equivalent strength.
######################################################################
Min_Bitsize=3072

######################################################################
## Max_Bitsize is the size in bits of the largest DH modulus you want
## to generate.  It is currently limited to 8192 in OpenSSH, but may
## be increased in the future for added security.
######################################################################
Max_Bitsize=8192

######################################################################
## The Miller-Rabin primality test used to determine if candidates
## are actually prime is a probabilistic test.  The more rounds you
## survive, the more likely the prime candidate is an actual prime.
## The SSH default number of rounds is 100, but I sometimes set it
## to a higher value for an increased security margin since CPU time
## is relatively cheap (~5 days for Num_Iter=1000)
######################################################################
Num_Iter=100	# Default value on stock /etc/ssh/moduli file

######################################################################
## By default, we create new moduli files with a bitsize delta of 512
## bits (ie, 3072 bits, 3584 bits, 4096 bits, etc.).   You may just
## want to generate with a bitsize delta of 1024 bits, as it will cut
## the amount of work roughly in half, though you also only get half
## as many moduli
######################################################################
Bit_Delta=1024	# Default value on stock /etc/ssh/moduli file

######################################################################
## Determine if there is sufficient entropy in the Linux entropy pool
## and exit with helpful instructions if entropy is too low.
######################################################################
Entropy=`cat /proc/sys/kernel/random/entropy_avail`
if [ "${Entropy}" -lt "2000" ]; then
	echo
	echo "ERROR:  The kernel entropy pool is currently low."
	echo "        (${Entropy} bits out of a potential 4096 bits)."
	echo
	echo "Please install a entropy-harvesting daemon such as:"
	echo
	echo "Havaged   - http://www.issihosts.com/haveged/"
	echo "Rng-Tools - https://github.com/nhorman/rng-tools"
	echo
	echo "Please check the package management system for your"
	echo "OS (apt for Debian/Ubuntu, yum for RHEL/Centos) as the"
	echo "entropy-gathering daemons may be available that way."
	echo
	echo "Once installed, you can check the entropy pool by running:"
	echo
	echo "   cat /proc/sys/kernel/random/entropy_avail"
	echo
	echo "Entropy should be at least 2000 bits."
	echo
	exit 1
fi

######################################################################
## Determine the number of physical cores so prime tests can be
## distributed as best as possible to speed things up.
######################################################################
Num_Sockets=$(grep 'physical id' /proc/cpuinfo | sort -u | wc -l)
Cores_Per_Socket=$(grep 'cpu cores' /proc/cpuinfo | sort -u | cut -d ':' -f 2)
Num_Cores=$((${Num_Sockets}*${Cores_Per_Socket}))
echo "INFO:  ${Num_Cores} CPU cores available to generate primes"

######################################################################
## Function to lower all ssh-keygen operations to only run while
## the computer is idle
######################################################################
Set_Priority_Idle() {
	ionice -c Idle -p ${1}
	renice -n 19 ${1} > /dev/null 2>&1
}

######################################################################
## Function to waitloop while background jobs are still running
######################################################################
Wait_For_Job_Completion() {
	running=`jobs | grep Running | wc -l`
	while [ "${running}" -ne "0" ]
	do
	       	sleep 5
	       	running=`jobs | grep Running | wc -l`
	done
}

######################################################################
## Generate candidate primes for DH-GEX
######################################################################
Bitsize=${Min_Bitsize}
Cores_Running=0
while [ "${Bitsize}" -le "${Max_Bitsize}" ]; do

	while [ "${Cores_Running}" -lt "${Num_Cores}" -a "${Bitsize}" -le "${Max_Bitsize}" ]; do
		echo "INFO:  Generating candidate primes of bitsize ${Bitsize}"
		ssh-keygen -q -G bit_${Bitsize}.candidate -b ${Bitsize} > /dev/null 2>&1 &
		Set_Priority_Idle $!
		Cores_Running=$((${Cores_Running}+1))
		Bitsize=$((Bitsize+Bit_Delta))
	done

	while [ "${Cores_Running}" -ge "${Num_Cores}" ] ; do
	       	sleep 5
	       	Cores_Running=`jobs | grep Running | wc -l`
	done

	if [ "${Bitsize}" -le "${Max_Bitsize}" ]; then
		sleep 5
		Cores_Running=$((${Cores_Running}-1))
	fi
done

echo "INFO:  Waiting for candidate prime generation threads to complete..."
Wait_For_Job_Completion

######################################################################
## Now test candidate primes and find strong primes.
######################################################################
Bitsize=${Min_Bitsize}
Cores_Running=0
while [ "${Bitsize}" -le "${Max_Bitsize}" ]; do

	while [ "${Cores_Running}" -lt "${Num_Cores}" -a "${Bitsize}" -le "${Max_Bitsize}" ]; do
		echo "INFO:  Testing candidate primes of bitsize ${Bitsize} for primality"
		ssh-keygen -q -T bit_${Bitsize}.moduli -a ${Num_Iter} -f bit_${Bitsize}.candidate > /dev/null 2>&1 &
		Set_Priority_Idle $!
		Cores_Running=$((${Cores_Running}+1))
		Bitsize=$((Bitsize+Bit_Delta))
	done

	while [ "${Cores_Running}" -ge "${Num_Cores}" ] ; do
	       	sleep 5
	       	Cores_Running=`jobs | grep Running | wc -l`
	done

	if [ "${Bitsize}" -le "${Max_Bitsize}" ]; then
		sleep 5
		Cores_Running=$((${Cores_Running}-1))
	fi
done

echo "INFO:  Waiting for prime testing threads to complete..."
Wait_For_Job_Completion

######################################################################
## Merge all our new moduli files together
######################################################################
Bitsize=${Min_Bitsize}
TS=`date +%s`
echo "INFO:  Merging candidate moduli together into moduli.${TS}"
while [ ${Bitsize} -le ${Max_Bitsize} ]; do
	cat bit_${Bitsize}.moduli >> moduli.${TS}
	rm -f bit_${Bitsize}.moduli bit_${Bitsize}candidate
	Bitsize=$((Bitsize+Bit_Delta))
done

PWD=`pwd`
echo "INFO:  New moduli data saved to file ${PWD}/moduli.${TS}"
exit 0
