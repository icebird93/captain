require 'securerandom'
require 'net/http'
require 'uri'

# AWS specific class extender
class CaptainAws

	# Include base class (Captain)
	include CaptainBase

	# Initializate class
	def initialize(config)
		# Load baseclass' constructor
		super(config)

		# Initialize AWS specific variables
		_init_aws

		p @config if $debug
		puts "[OK] AWS initialized"
	end

	# Creates VM if needed
	def setup_create
		puts "Checking if instance is created..."
		_log("setup_create")

		# Check instance
		if (!@config["aws"]["instance"]) || @config["aws"]["instance"].length==0 || (_instance_terminated(@config["aws"]["instance"])) || (_instance_status(@config["aws"]["instance"]).eql? "")
			# Instance not running or specified
			puts "[INFO] Instance not running or specified" if $verbose
			puts "Creating instance..."
			@instance = _instance_create(@config["aws"]["ami"], @config["aws"]["type"], @config["aws"]["key"], @config["aws"]["security"])
			@setup["created"] = true
			puts "[OK] Created instance #{@instance}"
		else
			# Valid instance specified
			@instance = @config["aws"]["instance"]
		end
		return @instance
	end

	# Starts VM if needed
	def setup_instance
		if !@setup["instance"]
			# Checking instance
			@instance = @config["aws"]["instance"] if !@instance
			@instance = _instance_id if (!@instance) or (@instance.length==0)
			status = _instance_status(@instance)

			# Start instance
			if !(status.eql? "running")
				puts "Waiting for instance #{@instance}..."
				_log("setup_instance")
				raise "Instance cannot be started" if !_instance_start(@instance)

				# Safety sleep (to be ready for sure)
				puts "Waiting 60 more seconds for safety..."
				sleep(60)
			end

			# Get IP
			puts "Getting public IP of instance..."
			@ip = _instance_ip(@instance)
			_log("instance accessible at #{@ip}")
			@setup["instance"] = true
			puts "[INFO] #{@instance} is accessible at #{@ip}" if $verbose
		end

		puts "[OK] Instance is ready"
		return @ip
	end

	# Prepares environment
	def setup_environment
		puts "Preparing environment..."
		puts "[INFO] This might take a few minutes"
		_log("setup_environment")

		# Upload Puppet installer and run
		file_send($location+"/assets/#{@config["os"]}/install-puppet.sh", "~/install-puppet.sh")
		debug = command_send("cd; sudo chmod u+x install-puppet.sh; sudo ./install-puppet.sh; rm install-puppet.sh;")
		_log(debug)
		puts debug if $debug

		# Wait until it reboots
		retries = 10
		sleep(10)
		until (retries == 0) || (_instance_status(@instance).eql? "running") do
			retries -= 1
			sleep(10)
		end

		# Prepare manifest
		manifest = File.read($location+"/assets/#{@config["os"]}/puppetfile.pp")
		#manifest.gsub!('{mysql_root_username}', @sql["root"]["username"])
		File.open($location+"/tmp/puppetfile.pp", "w"){ |f| f.write(manifest) }

		# Upload Puppet manifest and apply
		file_send($location+"/tmp/puppetfile.pp", "~/puppetfile.pp")
		debug = command_send("cd; sudo puppet apply puppetfile.pp; rm puppetfile.pp;")
		File.delete($location+"/tmp/puppetfile.pp")
		_log(debug)
		puts debug if $debug

		puts "[OK] Environment is ready"
		return true
	end

	# Does tests
	def setup_test
		puts "Running tests..."
		_log("setup_test")

		puts "[OK] All done"
		return true
	end

	# Destroys VM
	def setup_destroy
		puts "Stopping instances..."
		_log("setup_destroy")

		# Stop running instance
		_instance_stop(@instance)

		puts "[OK] All instances stopped"
		return true
	end

	###################
	# Private methods #
	###################
	private

	# Initialize AWS variables
	def _init_aws
		# Reset status 
		@setup = {}

		# Fix missing parameters
		@config["aws"]["type"] = "t2.micro" if !@config["aws"]["type"]

		# Check parameters
		raise "No AMI specified" if !@config["aws"]["ami"]
		raise "No AWS keypair specified" if !@config["aws"]["key"]
	end

	# Check if instance was terminated
	def _instance_terminated(instance)
		status = `aws ec2 describe-instance-status --instance-ids #{instance} --query "InstanceStatuses[0]" --output text 2>/dev/null`
		return status.strip.eql? "None"
	end

	# Check instance status
	def _instance_status(instance)
		status = `aws ec2 describe-instance-status --instance-ids #{instance} --query "InstanceStatuses[0].InstanceState.Name" --output text 2>/dev/null`
		return status.strip
	end

	# Create instance in AWS
	def _instance_create(ami, type, keypair, security_group)
		instance = `aws ec2 run-instances --image-id ami-#{ami} --instance-type #{type} --key-name #{keypair} --security-group-ids #{security_group} --count 1 --query 'Instances[0].InstanceId' --output text 2>/dev/null`
		return instance.strip
	end

	# Start instance if not already started
	def _instance_start(instance)
		if !(_instance_status(instance).eql? "running")
			# Start instance
			`aws ec2 start-instances --instance-ids #{instance} 2>/dev/null`

			# Wait until it boots (or 40 attempts)
			retries = 40
			until (retries == 0) || (_instance_status(instance).eql? "running") do
				puts "[INFO] Instance is not yet running, waiting..." if $verbose
				sleep(10)
				retries -= 1
			end
			return false if retries==0
		end
		return true
	end

	# Get public IP of instance	
	def _instance_ip(instance)
		ip = `aws ec2 describe-instances --instance-ids #{instance} --query "Reservations[0].Instances[0].PublicIpAddress" --output text 2>/dev/null`
		return ip.strip
	end

	# Get instance ID for first VM
	def _instance_id()
		id = `aws ec2 describe-instances --query "Reservations[*].Instances[*].[State.Name, InstanceId]" --output text 2>/dev/null | grep "running" | awk '{print $2}'`
		return id.strip
	end

	# Stop instance
	def _instance_stop(instance)
		`aws ec2 stop-instances --instance-ids #{instance}` if _instance_status(instance).eql? "running"
	end

end