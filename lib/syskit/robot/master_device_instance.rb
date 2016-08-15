module Syskit
    module Robot
        # Subclass of DeviceInstance used to represent root devices
        class MasterDeviceInstance < DeviceInstance
            # The RobotDefinition instance we are built upon
            attr_reader :robot
            # The device name
            attr_reader :name
            # The device model, as a subclass of Device
            attr_reader :device_model
            # The device slaves, as a mapping from the slave's name to the
            # SlaveDeviceInstance object
            attr_reader :slaves
            # The communication busses this device is attached to
            attr_reader :com_busses
            # Additional specifications for deployment of the driver
            # @return [Syskit::InstanceRequirements]
            attr_reader :requirements

            def model; device_model end

            # Defined to be consistent with task and data service models
            def short_name
                "#{name}[#{model.short_name}]"
            end

            def pretty_print(pp)
                pp.text "MasterDeviceInstance(#{short_name}_dev)"
            end


            # The driver for this device
            # @return [BoundDataService]
            attr_reader :driver_model
            # Configuration data structure
            attr_reader :configuration
            # Block given to #configure to configure the device. It will be
            # yield a data structure that represents the set of properties of
            # the underlying task
            #
            # Note that it is executed twice. Once at loading time to verify
            # that the block is compatible with the data structure, and once at
            # runtime to actually configure the task
            attr_reader :configuration_block

            def initialize(robot, name, device_model, options,
                           driver_model, task_arguments)
                @robot, @name, @device_model, @task_arguments =
                    robot, name, device_model, task_arguments
                @slaves      = Hash.new
                @conf = Array.new
                @com_busses = Array.new

                driver_model = driver_model.to_instance_requirements
                @driver_model = driver_model.service
                @requirements = driver_model.to_component_model
                requirements.name = "#{name}_dev"
                requirements.with_arguments("#{driver_model.service.name}_dev" => self)
                requirements.with_arguments(**task_arguments)

                sample_size 1
                burst   0
            end

            def to_s
                "device(#{device_model}, as: #{full_name})"
            end

            def full_name
                name
            end

            # Whether this device should be hidden from the user interfaces
            attr_predicate :advanced?, true

            # Sets {#advanced?}
            def advanced
                @advanced = true
                self
            end

            # @deprecated
            def use_conf(*conf)
                Roby.warn_deprecated "MasterDeviceInstance#use_conf is deprecated. Use #with_conf instead"
                with_conf(*conf)
            end

            # Declares that the following configuration chain should be used for
            # this device
            def with_conf(*conf)
                requirements.with_conf(*conf)
                self
            end

            # True if this device is attached to the given combus
            def attached_to?(com_bus)
                com_busses.include?(com_bus)
            end

            # The data service of {#driver_model} that is used to receive data from
            # the attached com bus for this device. If nil, the task is not
            # expecting to receive any data from the communication bus (only
            # send)
            #
            # @return [BoundDataService,nil]
            attr_reader :combus_client_in_srv

            # The data service of {#driver_model} that is used to send data to
            # the attached com bus for this device. If nil, the task is not
            # expecting to send any data from the communication bus (only
            # receives)
            #
            # @return [BoundDataService,nil]
            attr_reader :combus_client_out_srv

            # Whether this device sends messages to the bus it is attached to
            #
            # It will return false if not attached to a bus
            def client_to_bus?
                !!combus_client_out_srv
            end

            # Whether this device sends messages to the bus it is attached to
            #
            # It will return false if not attached to a bus
            def bus_to_client?
                !!combus_client_in_srv
            end

            # Attaches this device on the given communication bus
	    #
            # @param [Boolean,String] bus_to_client whether the device expects a
            #   connection from the bus. It can be set to a string, in which
            #   case the string is used as the name of the service on the
            #   client's device driver that should be used for connection
            # @param [Boolean,String] client_to_bus whether the device expects a
            #   connection to the bus. It can be set to a string, in which
            #   case the string is used as the name of the service on the client
            #   device driver that should be used for connection
            def attach_to(com_bus, bus_to_client: true, client_to_bus: true, **options)
                if com_bus.respond_to?(:to_str)
                    com_bus, com_bus_name = robot.find_device(com_bus), com_bus
                    if !com_bus
                        raise ArgumentError, "no device declared with the name '#{com_bus_name}'"
                    end
                end

                if srv_name = options.delete(:in)
                    Roby.warn_deprecated "the in: option of MasterDeviceInstance#attach_to has been renamed to bus_to_client"
                    bus_to_client = srv_name
                end
                if srv_name = options.delete(:out)
                    Roby.warn_deprecated "the out: option of MasterDeviceInstance#attach_to has been renamed to client_to_bus"
                    client_to_bus = srv_name
                end
                if !options.empty?
                    raise ArgumentError, "unexpected options #{options}"
                end

                if bus_to_client && com_bus.model.bus_to_client?
                    client_in_srv =
                        if bus_to_client.respond_to?(:to_str)
                            bus_to_client
                        end
                    client_in_srv_m  = com_bus.model.client_in_srv
                    @combus_client_in_srv  =
                        begin find_combus_client_srv(client_in_srv_m, client_in_srv)
                        rescue AmbiguousServiceSelection
                            raise ArgumentError, "#{driver_model.to_component_model} provides more than one input service to connect to the com bus, select one explicitely with the bus_to_client option"
                        end
                    if !combus_client_in_srv
                        raise ArgumentError, "#{driver_model.to_component_model} does not provide an input service to connect to the com bus, and was expected to"
                    end
                end

                if client_to_bus && com_bus.model.client_to_bus?
                    client_out_srv =
                        if client_to_bus.respond_to?(:to_str)
                            client_to_bus
                        end
                    client_out_srv_m  = com_bus.model.client_out_srv
                    @combus_client_out_srv  =
                        begin find_combus_client_srv(client_out_srv_m, client_out_srv)
                        rescue AmbiguousServiceSelection
                            raise ArgumentError, "#{driver_model.to_component_model} provides more than one output service to connect to the com bus, select one explicitely with the client_to_bus option"
                        end
                    if !combus_client_out_srv
                        raise ArgumentError, "#{driver_model.to_component_model} does not provide an output service to connect to the com bus, and was expected to"
                    end
                end

                com_busses << com_bus
                com_bus.attached_devices << self
                com_bus.model.apply_attached_device_configuration_extensions(self)
                self
            end
            
            # Finds in {#driver_model}.component_model the data service that should be used to
            # interface with a combus
            #
            # @param [Model<DataService>] srv_m the data service model for the client
            #   interface to the combus
            # @param [String,nil] srv_name the expected data service name, or nil if none
            #   is given. In this case, one is searched by type
            def find_combus_client_srv(srv_m, srv_name)
                driver_task_model = driver_model.to_component_model
		if srv_name
		    result = driver_task_model.find_data_service(srv_name)
		    if !result
			raise ArgumentError, "#{srv_name} is specified as a client service on device #{name} for combus #{com_bus.name}, but it is not a data service on #{driver_task_model}"
                    elsif !result.fullfills?(srv_m)
                        raise ArgumentError, "#{srv_name} is specified as a client service on device #{name} for combus #{com_bus.name}, but it does not provide the required service from #{com_bus.model}"
		    end
                    result
		else
		    driver_task_model.find_data_service_from_type(srv_m)
		end
            end

            KNOWN_PARAMETERS = { :period => nil, :sample_size => nil, :device_id => nil }

            ## 
            # :method:device_id
            #
            # call-seq:
            #   device_id(device_id, definition)
            #   device_id => current_id or nil
            #
            # The device ID. It is dependent on the method of communication to
            # the device. For a serial line, it would be the device file
            # (/dev/ttyS0):
            #
            #   device(XsensImu).
            #       device_id('/dev/ttyS0')
            #
            # For CAN, it would be the device ID and mask:
            #
            #   device(Motors).
            #       device_id(0x0, 0x700)
            #
            dsl_attribute(:device_id) do |*values|
                if values.size > 1
                    values
                else
                    values.first
                end
            end

            # Enumerates the slaves that are known for this device, as
            # [slave_name, SlaveDeviceInstance object] pairs
            def each_slave(&block)
                slaves.each_value(&block)
            end

            # Gets the required slave device, or creates a dynamic one
            #
            # @overload slave(slave_name)
            #   @param [String] slave_name the name of a slave service on the
            #     device's driver 
            #   @return [Syskit::Robot::SlaveDeviceInstance]
            #
            # @overload slave(dynamic_service_name, :as => slave_name)
            #   @param [String] dynamic_service_name the name of a dynamic service
            #     declared on the device's driver with #dynamic_service
            #   @param [String] slave_name the name of the slave as it should be
            #     created
            #   @return [Syskit::Robot::SlaveDeviceInstance]
            #   
            def slave(slave_service, as: nil)
                if existing_slave = slaves[slave_service]
                    return existing_slave
                end

                # If slave_service is a string, it should refer to an actual
                # service on +task_model+
                task_model = driver_model.to_component_model

                slave_name = "#{driver_model.full_name}.#{slave_service}"
                srv = task_model.find_data_service(slave_name)
                if !srv
                    if as
                        new_task_model = task_model.ensure_model_is_specialized
                        srv = new_task_model.require_dynamic_service(slave_service, as: as)
                    end
                    if !srv
                        raise ArgumentError, "there is no service #{slave_name} and no dynamic service in #{task_model.short_name}"
                    end
                    @driver_model = driver_model.attach(new_task_model)
                end

                device_instance = SlaveDeviceInstance.new(self, srv)
                slaves[srv.name] = device_instance
                if srv.model.respond_to?(:apply_device_configuration_extensions)
                    srv.model.apply_device_configuration_extensions(device_instance)
                end
                robot.devices["#{name}.#{srv.name}"] = device_instance
            end

            def method_missing(m, *args, &block)
                if m.to_s =~ /(.*)_dev$/
                    if !args.empty?
                        raise ArgumentError, "expected no arguments, got #{args.size}"
                    end
                    return slave($1)
                end
                super
            end

            # If this device's driver is a composition, allows to specify
            # dependency injections for it
            def use(dependency_injection)
                requirements.use(dependency_injection)
                self
            end

            # Add arguments to the underlying device driver
            def with_arguments(arguments = Hash.new)
                requirements.with_arguments(arguments)
                self
            end

            # Specify deployment selection hints for the device's driver
	    def prefer_deployed_tasks(hints)
		requirements.prefer_deployed_tasks(hints)
		self
	    end

            def use_deployments(hints)
                Roby.warn_deprecated "MasterDeviceInstance#use_deployments is deprecated. Use #prefer_deployed_tasks instead"
                prefer_deployed_tasks(hints)
                self
            end

            # Returns the InstanceRequirements object that can be used to
            # represent this device
            def to_instance_requirements
                result = requirements.dup
                robot.inject_di_context(result)
                result.select_service(driver_model)
                result
            end

            # Create an action model that represent an instanciation of this
            # device
            #
            # @param [Profile] profile the underlying profile that define the
            #   instanciation context
            # @return [Actions::Model::Action]
            def to_action_model(profile)
                req = to_instance_requirements
                profile.inject_di_context(req)
                action_model = Actions::Models::Action.
                    new(profile, req, doc || "device from profile #{profile.name}")
                action_model.name = "#{name}_dev"
                action_model
            end

            def as_plan; to_instance_requirements.as_plan end

            def each_fullfilled_model(&block)
                device_model.each_fullfilled_model(&block)
            end

            DRoby = Struct.new :name, :device_model, :driver_model do
                def proxy(peer)
                    MasterDeviceInstance.new(nil, name, peer.local_object(device_model), Hash.new, peer.local_object(driver_model), Hash.new)
                end
            end
            def droby_dump(peer)
                DRoby.new(name, peer.dump(device_model), peer.dump(driver_model))
            end
        end
    end
end

