module Syskit
    module Test
        # Network manipulation functionality (stubs, ...) useful in tests
        module NetworkManipulation
            def setup
                @__test_created_deployments = Array.new
                @__test_overriden_configurations = Array.new
                @__test_deployment_group = Models::DeploymentGroup.new
                super
            end

            def teardown
                super
                @__test_overriden_configurations.each do |model, manager|
                    model.configuration_manager = manager
                end
            end

            # Ensure that any modification made to a model's configuration
            # manager are undone at teardown
            def syskit_protect_configuration_manager(model)
                manager = model.configuration_manager
                model.configuration_manager = manager.dup
                @__test_overriden_configurations << [model, manager]
            end

            def use_deployment(*args)
                @__test_deployment_group.use_deployment(*args)
            end

            def use_ruby_tasks(*args)
                @__test_deployment_group.use_ruby_tasks(*args)
            end

            def use_unmanaged_task(*args)
                @__test_deployment_group.use_unmanaged_task(*args)
            end

            def normalize_instanciation_models(to_instanciate)
                # Instanciate all actions until we have a syskit instance
                # requirement pattern
                while true
                    action_tasks, to_instanciate = to_instanciate.partition do |t|
                        t.respond_to?(:planning_task) &&
                            t.planning_task.pending? &&
                            !t.planning_task.respond_to?(:requirements)
                    end
                    if action_tasks.empty?
                        break
                    else
                        action_tasks.each do |t|
                            tracker = t.as_service
                            assert_event_emission(t.planning_task.success_event) do
                                t.planning_task.start!
                            end
                            to_instanciate << tracker.task
                        end
                    end
                end
                to_instanciate
            end

            def syskit_generate_network(*to_instanciate, add_missions: true)
                to_instanciate = normalize_instanciation_models(to_instanciate)
                placeholders = to_instanciate.map(&:as_plan)
                if add_missions
                    placeholders.each do |t|
                        plan.add_mission_task(t)
                        t.planning_task.start_event.emit
                    end
                end
                task_mapping = plan.in_transaction do |trsc|
                    engine = NetworkGeneration::Engine.new(plan)
                    mapping = engine.compute_system_network(
                        placeholders.map(&:planning_task),
                        plan: trsc,
                        validate_generated_network: false)
                    trsc.commit_transaction
                    mapping
                end
                placeholders.map do |task|
                    replacement = task_mapping[task.planning_task]
                    plan.replace_task(task, replacement)
                    plan.remove_task(task)
                    replacement.planning_task.success_event.emit
                    replacement
                end
            end

            # Run Syskit's deployer (i.e. engine) on the current plan
            def syskit_deploy(*to_instanciate, add_mission: true, syskit_engine: nil, **resolve_options, &block)
                to_instanciate = to_instanciate.flatten # For backward-compatibility
                to_instanciate = normalize_instanciation_models(to_instanciate)

                emit_calls = Set.new
                placeholder_tasks = to_instanciate.map do |act|
                    if act.respond_to?(:to_action)
                        act = act.to_action
                    end
                    plan.add(task = act.as_plan)
                    if add_mission
                        plan.add_mission_task(task)
                    end
                    task
                end.compact
                root_tasks = placeholder_tasks.map(&:as_service)
                requirement_tasks = placeholder_tasks.map(&:planning_task)
                requirement_tasks.each do |task|
                    task.requirements.deployment_group.use_group!(@__test_deployment_group)
                end

                plan.execution_engine.process_events_synchronous do
                    requirement_tasks.each { |t| t.start! }
                end

                begin
                    syskit_engine_resolve_handle_plan_export do
                        syskit_engine ||= Syskit::NetworkGeneration::Engine.new(plan)
                        syskit_engine.resolve(**(Hash[on_error: :commit].merge(resolve_options)))
                    end
                rescue Exception => e
                    begin
                        plan.execution_engine.process_events_synchronous do
                            requirement_tasks.each { |t| t.failed_event.emit(e) }
                        end
                    rescue Roby::PlanningFailedError
                        # Emitting failed_event will cause the engine to raise
                        # PlanningFailedError
                    end
                    raise
                end

                plan.execution_engine.process_events_synchronous do
                    requirement_tasks.each { |t| t.success_event.emit if !t.finished? }
                end
                placeholder_tasks.each do |task|
                    plan.remove_task(task)
                end

                root_tasks = root_tasks.map(&:task)
                if root_tasks.size == 1
                    return root_tasks.first
                elsif root_tasks.size > 1
                    return root_tasks
                end
            end

            def syskit_engine_resolve_handle_plan_export
                failed = false
                yield
            rescue Exception => e
                failed = true
                raise
            ensure
                if Roby.app.public_logs?
                    filename = name.gsub("/", "_")
                    dataflow_base, hierarchy_base = filename + "-dataflow", filename + "-hierarchy"
                    if failed
                        dataflow_base += "-FAILED"
                        hierarchy_base += "-FAILED"
                    end
                    dataflow = File.join(Roby.app.log_dir, "#{dataflow_base}.svg")
                    hierarchy = File.join(Roby.app.log_dir, "#{hierarchy_base}.svg")
                    while File.file?(dataflow) || File.file?(hierarchy)
                        i ||= 1
                        dataflow = File.join(Roby.app.log_dir, "#{dataflow_base}.#{i}.svg")
                        hierarchy = File.join(Roby.app.log_dir, "#{hierarchy_base}.#{i}.svg")
                        i = i + 1
                    end

                    Graphviz.new(plan).to_file('dataflow', 'svg', dataflow)
                    Graphviz.new(plan).to_file('hierarchy', 'svg', hierarchy)
                end
            end

            # Create a new task context model with the given name
            #
            # @yield a block in which the task context interface can be
            #   defined
            def syskit_stub_task_context_model(name, &block)
                model = TaskContext.new_submodel(name: name, &block)
                model.orogen_model.extended_state_support
                model
            end

            def syskit_stub_configured_deployment(task_model = nil, name = nil, register: true, &block)
                if task_model
                    task_model = task_model.to_component_model
                end
                name ||= syskit_default_stub_name(task_model)
                deployment_model = Deployment.new_submodel(name: name) do
                    if task_model
                        task(name, task_model.orogen_model)
                    end
                    if block_given?
                        instance_eval(&block)
                    end
                end

                deployment = Models::ConfiguredDeployment.new('stubs', deployment_model, Hash[name => name], name)
                if register
                    @__test_deployment_group.register_configured_deployment(deployment)
                end
                deployment
            end

            # Create a new stub deployment model that can deploy a given task
            # context model
            #
            # @param [Model<Syskit::TaskContext>,nil] task_model if given, a
            #   task model that should be deployed by this deployment model
            # @param [String] name the name of the deployed task as well as
            #   of the deployment. If not given, and if task_model is provided,
            #   task_model.name is used as default
            # @yield the deployment model context, i.e. a context in which the
            #   same declarations than in oroGen's #deployment statement are
            #   available
            # @return [Models::ConfiguredDeployment] the configured deployment
            def syskit_stub_deployment_model(task_model = nil, name = nil, &block)
                configured_deployment = syskit_stub_configured_deployment(task_model, name, &block)
                configured_deployment.model
            end

            # Create a new stub deployment instance, optionally stubbing the
            # model as well
            def syskit_stub_deployment(name = "deployment", deployment_model = nil, &block)
                deployment_model ||= syskit_stub_deployment_model(nil, name, &block)
                plan.add_permanent_task(task = deployment_model.new(process_name: name, on: 'stubs'))
                task
            end

            def syskit_stub_component(model, devices: true)
                if devices
                    syskit_stub_required_devices(model)
                else
                    model
                end
            end

            # @api private
            #
            # Helper for {#syskit_stub_and_deploy}
            #
            # @param [InstanceRequirements] model the task context model
            # @param [String] as the deployment name
            # @param [Boolean] devices whether devices needed by the task should
            #   be automatically stubbed as well
            def syskit_stub_task_context_requirements(model, as: syskit_default_stub_name(model), devices: true)
                model = model.to_instance_requirements

                task_m = model.model.to_component_model.concrete_model
                if task_m.respond_to?(:proxied_data_services)
                    superclass = if task_m.superclass <= Syskit::TaskContext
                                     task_m.superclass
                                 else Syskit::TaskContext
                                 end

                    services = task_m.proxied_data_services
                    task_m = superclass.new_submodel(name: "#{task_m.to_s}-stub")
                    services.each_with_index do |srv, idx|
                        srv.each_input_port do |p|
                            task_m.orogen_model.input_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                        end
                        srv.each_output_port do |p|
                            task_m.orogen_model.output_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                        end
                        if srv <= Syskit::Device
                            task_m.driver_for srv, as: "dev#{idx}"
                        else
                            task_m.provides srv, as: "srv#{idx}"
                        end
                    end
                elsif task_m.abstract?
                    task_m = task_m.new_submodel(name: "#{task_m.name}-stub")
                end
                model.add_models([task_m])
                model = syskit_stub_component(model, devices: devices)

                syskit_stub_conf(task_m, *model.arguments[:conf])

                deployment = syskit_stub_configured_deployment(task_m, as, register: false)
                model.reset_deployment_selection
                model.use_configured_deployment(deployment)
                model
            end

            # Create empty configuration sections for the given task model
            def syskit_stub_conf(task_m, *conf)
                concrete_task_m = task_m.concrete_model
                syskit_protect_configuration_manager(concrete_task_m)
                conf.each do |conf_name|
                    concrete_task_m.configuration_manager.add(conf_name, Hash.new, merge: true)
                end
            end

            # @api private
            #
            # Helper for {#syskit_stub}
            #
            # @param [InstanceRequirements] model
            def syskit_stub_composition_requirements(model, recursive: true, as: syskit_default_stub_name(model), devices: true)
                model = syskit_stub_component(model, devices: devices)

                if recursive
                    model.each_child do |child_name, selected_child|
                        if selected_task = selected_child.component
                            deployed_child = selected_task
                        else
                            child_model = selected_child.selected
                            selected_service = child_model.service
                            child_model = child_model.to_component_model
                            if child_model.composition_model? 
                                deployed_child = syskit_stub_composition_requirements(
                                    child_model, recursive: true, as: "#{as}_#{child_name}", devices: devices)
                            else
                                deployed_child = syskit_stub_task_context_requirements(
                                    child_model, as: "#{as}_#{child_name}", devices: devices)
                            end
                            if selected_service
                                deployed_child.select_service(selected_service)
                            end
                        end
                        model.use(child_name => deployed_child)
                    end
                end

                model
            end

            # @api private
            #
            # Finds a driver model for a given device model, or create one if
            # there is none
            def syskit_stub_driver_model_for(model)
                syskit_stub_requirements(model.find_all_drivers.first || model, devices: false)
            end

            # Create a stub device of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<Device>] model the device model
            # @param [String] as the device name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def syskit_stub_device(model, as: syskit_default_stub_name(model), driver: nil, robot: nil, **device_options)
                robot ||= Syskit::Robot::RobotDefinition.new
                driver ||= syskit_stub_driver_model_for(model)
                robot.device(model, as: as, using: driver, **device_options)
            end

            # Create a stub combus of the given model
            #
            # It is created on a new robot instance so that to avoid clashes
            #
            # @param [Model<ComBus>] model the device model
            # @param [String] as the combus name
            # @param [Model<TaskContext>] driver the driver that should be used.
            #   If not given, a new driver is stubbed
            def syskit_stub_com_bus(model, as: syskit_default_stub_name(model), driver: nil, robot: nil, **device_options)
                robot ||= Syskit::Robot::RobotDefinition.new
                driver ||= syskit_stub_driver_model_for(model)
                robot.com_bus(model, as: as, using: driver, **device_options)
            end

            # Create a stub device attached on the given bus
            #
            # If the bus is a device object, the new device is attached to the
            # same robot model. Otherwise, a new robot model is created for both
            # the bus and the device
            #
            # @param [Model<ComBus>,MasterDeviceInstance] bus either a bus model
            #   or a bus object
            # @param [String] as a name for the new device
            def syskit_stub_attached_device(bus, as: syskit_default_stub_name(bus))
                if !bus.kind_of?(Robot::DeviceInstance)
                    bus = syskit_stub_com_bus(bus, as: "#{as}_bus")
                end
                bus_m = bus.model
                dev_m = Syskit::Device.new_submodel(name: "#{bus}-stub") do
                    provides bus_m::ClientSrv
                end
                dev = syskit_stub_device(dev_m, as: as)
                dev.attach_to(bus)
                dev
            end

            # Stubs the devices required by the given model
            def syskit_stub_required_devices(model)
                model = model.to_instance_requirements
                model.model.to_component_model.each_master_driver_service do |srv|
                    if !model.arguments["#{srv.name}_dev"]
                        model.with_arguments("#{srv.name}_dev" => syskit_stub_device(srv.model, driver: model.model))
                    end
                end
                model
            end

            @@syskit_stub_model_id = -1

            def syskit_stub_model_id
                id = (@@syskit_stub_model_id += 1)
                if id != 0
                    id
                end
            end

            def syskit_default_stub_name(model)
                model_name =
                    if model.respond_to?(:name) then model.name
                    else model.to_str
                    end
                "stub#{syskit_stub_model_id}"
            end

            # @deprecated use syskit_stub_requirements instead
            def syskit_stub(*args, **options, &block)
                Roby.warn_deprecated "syskit_stub has been renamed to syskit_stub_requirements to make the difference with syskit_stub_network more obvious"
                syskit_stub_requirements(*args, **options, &block)
            end

            # Create an InstanceRequirement instance that would allow to deploy
            # the given model
            def syskit_stub_requirements(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), devices: true, &block)
                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                model = model.to_instance_requirements.dup

                if model.composition_model?
                    syskit_stub_composition_requirements(model, recursive: recursive, as: as, devices: devices)
                else
                    syskit_stub_task_context_requirements(model, as: as, devices: devices)
                end
            end

            # Stub an already existing network
            def syskit_stub_network(root_tasks)
                tasks = Set.new
                dependency_graph = plan.task_relation_graph_for(Roby::TaskStructure::Dependency)
                root_tasks = root_tasks.map do |t|
                    tasks << t
                    dependency_graph.depth_first_visit(t) do |child_t|
                        tasks << child_t
                    end

                    if plan.mission_task?(t)
                        [t, :mission_task]
                    elsif plan.permanent_task?
                        [t, :permanent_task]
                    else
                        [t]
                    end
                end

                mapped_tasks = Hash.new
                # NOTE: must NOT call #apply_merge_group with merge_mappings
                # directly. #apply_merge_group "replaces" the subnet represented
                # by the keys with the subnet represented by the values. In
                # other words, the connections present between two keys would
                # NOT be copied between the corresponding values
                plan.in_transaction do |trsc|
                    trsc_tasks = tasks.map { |t| trsc[t] }

                    merge_solver = NetworkGeneration::MergeSolver.new(trsc)
                    tasks.each do |plan_t|
                        merge_solver.register_replacement(plan_t, trsc[plan_t])
                    end
                    merge_mappings = Hash.new
                    stubbed_tags = Hash.new
                    trsc_tasks.each do |task|
                        task.model.each_master_driver_service do |srv|
                            task.arguments["#{srv.name}_dev"] ||=
                                syskit_stub_device(srv.model, driver: task.model)
                        end
                    end

                    trsc_tasks.find_all(&:abstract?).each do |abstract_task|
                        concrete_task =
                            if abstract_task.kind_of?(Syskit::Actions::Profile::Tag)
                                tag_id = [abstract_task.model.tag_name, abstract_task.model.profile.name]
                                stubbed_tags[tag_id] ||= syskit_stub_network_abstract_component(abstract_task)
                            else
                                syskit_stub_network_abstract_component(abstract_task)
                            end


                        if abstract_task.placeholder_task? && !abstract_task.kind_of?(Syskit::TaskContext) # 'pure' proxied data services
                            trsc.replace_task(abstract_task, concrete_task)
                            merge_solver.register_replacement(abstract_task, concrete_task)
                        else
                            merge_mappings[abstract_task] = concrete_task
                        end
                    end
                    merge_mappings.each do |original, replacement|
                        merge_solver.apply_merge_group(original => replacement)
                    end
                    merge_solver.merge_identical_tasks

                    merge_mappings = Hash.new
                    trsc_tasks.each do |original_task|
                        concrete_task = merge_solver.replacement_for(original_task)
                        if concrete_task.kind_of?(TaskContext) && !concrete_task.execution_agent
                            merge_mappings[concrete_task] = syskit_stub_network_deployment(concrete_task)
                        end
                    end
                    merge_mappings.each do |original, replacement|
                        merge_solver.apply_merge_group(original => replacement)
                    end

                    mapped_tasks = Hash.new
                    tasks.each do |plan_t|
                        replacement_t = merge_solver.replacement_for(plan_t)
                        mapped_tasks[plan_t] = trsc.may_unwrap(replacement_t)
                    end

                    root_tasks.each do |root_t, status|
                        replacement_t = mapped_tasks[root_t]
                        if replacement_t != root_t
                            replacement_t.planned_by trsc[root_t.planning_task]
                            trsc.send("add_#{status}", replacement_t)
                        end
                    end

                    trsc.static_garbage_collect
                    trsc.commit_transaction
                end

                mapped_tasks.each do |old, new|
                    if old != new
                        plan.remove_task(old)
                    end
                end
                root_tasks.map { |t, _| mapped_tasks[t] }
            end

            def syskit_stub_proxied_data_service(model)
                superclass = if model.superclass <= Syskit::TaskContext
                                 model.superclass
                             else Syskit::TaskContext
                             end

                services = model.proxied_data_services
                task_m = superclass.new_submodel(name: "#{model.to_s}-stub")
                services.each_with_index do |srv, idx|
                    srv.each_input_port do |p|
                        task_m.orogen_model.input_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                    end
                    srv.each_output_port do |p|
                        task_m.orogen_model.output_port p.name, Orocos.find_orocos_type_name_by_type(p.type)
                    end
                    if srv <= Syskit::Device
                        task_m.driver_for srv, as: "dev#{idx}"
                    else
                        task_m.provides srv, as: "srv#{idx}"
                    end
                end
                task_m
            end

            def syskit_stub_network_abstract_component(task)
                task_m = task.concrete_model
                if task_m.respond_to?(:proxied_data_services)
                    task_m = syskit_stub_proxied_data_service(task_m)
                elsif task_m.abstract?
                    task_m = task_m.new_submodel(name: "#{task_m.name}-stub")
                end

                arguments = task.arguments.dup
                task_m.each_master_driver_service do |srv|
                    arguments["#{srv.name}_dev"] ||=
                        syskit_stub_device(srv.model, driver: task_m)
                end
                task_m.new(arguments)
            end

            def syskit_stub_network_deployment(task, as: syskit_default_stub_name(task.model))
                task_m = task.concrete_model
                deployment_model = syskit_stub_configured_deployment(task_m, as, register: false)
                syskit_stub_conf(task_m, *task.arguments[:conf])
                task.plan.add(deployer = deployment_model.new)
                deployed_task = deployer.instanciate_all_tasks.first

                new_args = task.arguments.find_all do |key, arg|
                    deployed_task.arguments.writable?(key, arg)
                end
                deployed_task.assign_arguments(new_args)
                deployed_task
            end

            def syskit_start_all_execution_agents
                plan.add_permanent_event(sync_ev = Roby::EventGenerator.new)

                agents = plan.each_task.map do |t|
                    if t.respond_to?(:should_configure_after)
                        t.should_configure_after(sync_ev)
                    end
                    if t.execution_agent && !t.execution_agent.ready?
                        t.execution_agent
                    end
                end.compact
                
                agents.each do |agent|
                    # Protect the component against configuration and 
                    if !agent.running?
                        agent.start!
                    end
                end

                agents.each do |agent|
                    if !agent.ready?
                        assert_event_emission agent.ready_event
                    end
                end
            ensure
                if sync_ev
                    plan.remove_free_event(sync_ev)
                end
            end

            def syskit_start_execution_agents(component, recursive: true)
                # Protect the component against configuration and startup
                plan.add_permanent_event(sync_ev = Roby::EventGenerator.new)
                component.should_configure_after(sync_ev)

                if recursive
                    component.each_child do |child_task|
                        syskit_start_execution_agents(child_task, recursive: true)
                    end
                end

                if agent = component.execution_agent
                    # Protect the component against configuration and 
                    if !agent.running?
                        agent.start!
                    end
                    if !agent.ready?
                        assert_event_emission agent.ready_event
                    end
                end
            ensure
                if sync_ev
                    plan.remove_free_event(sync_ev)
                end
            end

            def syskit_prepare_configure(component, tasks, sync_ev, recursive: true, except: Set.new)
                component.should_start_after(sync_ev)
                component.freeze_delayed_arguments

                tasks << component

                if recursive
                    component.each_child do |child_task|
                        if except.include?(child_task)
                            next
                        elsif child_task.respond_to?(:setup?)
                            syskit_prepare_configure(child_task, tasks, sync_ev, recursive: true, except: except)
                        end
                    end
                end
            end

            class NoConfigureFixedPoint < RuntimeError
                attr_reader :tasks
                attr_reader :info
                Info = Struct.new :ready_for_setup, :missing_arguments, :precedence, :missing

                def initialize(tasks)
                    @tasks = tasks
                    @info = Hash.new
                    tasks.each do |t|
                        precedence = t.start_event.parent_objects(Roby::EventStructure::SyskitConfigurationPrecedence).to_a
                        missing = precedence.find_all { |ev| !ev.emitted? }
                        info[t] = Info.new(
                            t.ready_for_setup?,
                            t.list_unset_arguments,
                            precedence, missing)
                    end
                end
                def pretty_print(pp)
                    pp.text "cannot find an ordering to configure #{tasks.size} tasks"
                    tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)

                        info = self.info[t]
                        pp.nest(2) do
                            pp.breakable
                            pp.text "ready_for_setup? #{info.ready_for_setup}"
                            pp.breakable
                            if info.missing_arguments.empty?
                                pp.text "is fully instanciated"
                            else
                                pp.text "missing_arguments: #{info.missing_arguments.join(", ")}"
                            end

                            pp.breakable
                            if info.precedence.empty?
                                pp.text "has no should_configure_after constraint"
                            else
                                pp.text "is waiting for #{info.missing.size} events to happen before continuing, among #{info.precedence.size}"
                                pp.nest(2) do
                                    info.missing.each do |ev|
                                        pp.breakable
                                        ev.pretty_print(pp)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            # Set this component instance up
            def syskit_configure(component, recursive: true, except: Set.new)
                plan.add_permanent_event(sync_ev = Roby::EventGenerator.new)
                # We need all execution agents to be started to connect (and
                # therefore configur) the tasks
                syskit_start_all_execution_agents

                tasks = Set.new
                except  = except.to_set
                syskit_prepare_configure(component, tasks, sync_ev, recursive: recursive, except: except)

                pending = tasks.dup.to_set
                while !pending.empty?
                    Syskit::Runtime::ConnectionManagement.update(component.plan)
                    current_state = pending.size
                    pending.delete_if do |t|
                        if !t.setup? && t.ready_for_setup?
                            Runtime.start_task_setup(t)
                            execution_engine.join_all_waiting_work
                            assert t.setup?, "ran the setup for #{t}, but t.setup? does not return true"
                            true
                        else
                            t.setup?
                        end
                    end
                    if current_state == pending.size
                        raise NoConfigureFixedPoint.new(pending), "cannot configure #{pending.map(&:to_s).join(", ")}"
                    end
                end

                component

            ensure
                plan.remove_free_event(sync_ev)
            end
            
            class NoStartFixedPoint < RuntimeError
                attr_reader :tasks

                def initialize(tasks)
                    @tasks = tasks
                end

                def pretty_print(pp)
                    pp.text "cannot find an ordering to start #{tasks.size} tasks"
                    tasks.each do |t|
                        pp.breakable
                        t.pretty_print(pp)
                    end
                end
            end

            def syskit_prepare_start(component, tasks, recursive: true, except: Set.new)
                tasks << component

                if recursive
                    component.each_child do |child_task|
                        if except.include?(child_task)
                            next
                        elsif child_task.respond_to?(:setup?)
                            syskit_prepare_start(child_task, tasks, recursive: true, except: except)
                        end
                    end
                end
            end
            # Start this component
            def syskit_start(component, recursive: true, except: Set.new)
                tasks = Set.new
                except = except.to_set
                syskit_prepare_start(component, tasks, recursive: recursive, except: except)

                pending = tasks.dup
                while !pending.empty?
                    current_state = pending.size
                    pending.delete_if do |t|
                        if t.starting? || t.running?
                            true
                        elsif t.executable?
                            if !t.setup?
                                raise "#{t} is not set up, call #syskit_configure first"
                            end
                            t.start!
                            true
                        end
                    end

                    if current_state == pending.size
                        try_again = tasks.any? do |t|
                            if t.starting?
                                assert_event_emission t.start_event
                                true
                            end
                        end

                        if !try_again
                            raise NoStartFixedPoint.new(pending), "cannot start #{pending.map(&:to_s).join(", ")}"
                        end
                    end
                end

                tasks.each do |t|
                    if t.starting?
                        assert_event_emission t.start_event
                    end
                end

                if t = tasks.find { |t| !t.running? }
                    raise RuntimeError, "failed to start #{t}: starting=#{t.starting?} running=#{t.running?} finished=#{t.finished?}"
                end

                component
            end

            # Deploy the given composition, replacing every single data service
            # and task context by a ruby task context, allowing to then test.
            #
            # @param [Boolean] recursive (false) if true, the method will stub
            #   the children of compositions that are used by the root
            #   composition. Otherwise, you have to refer to them in the original
            #   instance requirements
            #
            # @example reuse toplevel tasks in children-of-children
            #   class Cmp < Syskit::Composition
            #      add PoseSrv, :as => 'pose'
            #   end
            #   class RootCmp < Syskit::Composition
            #      add PoseSrv, :as => 'pose'
            #      add Cmp, :as => 'processor'
            #   end
            #   model = RootCmp.use(
            #      'processor' => Cmp.use('pose' => RootCmp.pose_child))
            #   syskit_stub_deploy_and_start_composition(model)
            def syskit_stub_and_deploy(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), &block)
                if model.respond_to?(:to_str)
                    model = syskit_stub_task_context_model(model, &block)
                end
                tasks = syskit_generate_network(model, &block)
                tasks = syskit_stub_network(tasks)
                tasks.first
            end

            # Stub a task, deploy it and configure it
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_and_configure(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), &block)
                root = syskit_stub_and_deploy(model, recursive: recursive, as: as, &block)
                syskit_configure(root, recursive: recursive)
                root
            end

            # Stub a task, deploy it, configure it and start the task and
            # the underlying stub deployment
            #
            # This starts the underlying (stubbed) deployment process
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            # @see syskit_stub
            def syskit_stub_deploy_configure_and_start(model = subject_syskit_model, recursive: true, as: syskit_default_stub_name(model), &block)
                root = syskit_stub_and_deploy(model, recursive: recursive, as: as, &block)
                syskit_configure_and_start(root, recursive: recursive)
                root
            end

            # Deploy and configure a model
            #
            # Unlike {#syskit_stub_deploy_and_configure}, it does not stub the
            # model, so model has to be deploy-able as-is.
            #
            # @param [#to_instance_requirements] model the requirements to
            #   deploy and configure
            # @param [Boolean] recursive if true, children of the provided model
            #   will be configured as well. Otherwise, only the toplevel task
            #   will
            # @return [Syskit::Component]
            def syskit_deploy_and_configure(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure(root, recursive: recursive)
            end

            # Deploy, configure and start a model
            #
            # Unlike {#syskit_stub_deploy_configure_and_start}, it does not stub
            # the model, so model has to be deploy-able as-is.
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            def syskit_deploy_configure_and_start(model = subject_syskit_model, recursive: true)
                root = syskit_deploy(model)
                syskit_configure_and_start(root, recursive: recursive)
            end

            # Configure and start a task
            #
            # Unlike {#syskit_stub_deploy_configure_and_start}, it does not stub
            # the model, so model has to be deploy-able as-is.
            #
            # @param (see syskit_stub)
            # @return [Syskit::Component]
            def syskit_configure_and_start(component = subject_syskit_model, recursive: true, except: Set.new)
                component = syskit_configure(component, recursive: recursive, except: except)
                syskit_start(component, recursive: recursive, except: except)
            end

            # Export the dataflow and hierarchy to SVG
            def syskit_export_to_svg(plan = self.plan, suffix: '')
                basename = 'syskit-export-%i%s.%s.svg'

                counter = 0
                Dir.glob('syskit-export-*') do |file|
                    if file =~ /syskit-export-(\d+)/
                        counter = [counter, Integer($1)].max
                    end
                end

                dataflow = basename % [counter + 1, suffix, 'dataflow']
                hierarchy = basename % [counter + 1, suffix, 'hierarchy']
                Syskit::Graphviz.new(plan).to_file('dataflow', 'svg', dataflow)
                Syskit::Graphviz.new(plan).to_file('hierarchy', 'svg', hierarchy)
                ::Robot.info "exported plan to #{dataflow} and #{hierarchy}"
            end
        end
    end
end

