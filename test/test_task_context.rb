require 'syskit/test/self'

module Syskit
    describe TaskContext do
        # Helper method that mocks a port accessed through
        # Orocos::TaskContext#raw_port
        def mock_raw_port(task, port_name)
            if task.respond_to?(:orocos_task)
                task = task.orocos_task
            end

            port = Orocos.allow_blocking_calls do
                task.raw_port(port_name)
            end
            task.should_receive(:raw_port).with(port_name).and_return(port)
            flexmock(port)
        end

        describe "#can_merge?" do
            attr_reader :merging_task, :merged_task
            before do
                task_m = TaskContext.new_submodel
                @merging_task = task_m.new
                @merged_task  = task_m.new
            end
            it "returns true for the same tasks" do
                assert merging_task.can_merge?(merged_task)
            end
            it "returns true if only one of the two tasks have a required host" do
                merging_task.required_host = 'host'
                assert merging_task.can_merge?(merged_task)
                assert merged_task.can_merge?(merging_task)
            end
            it "returns true if both tasks have a required host and it is identical" do
                merging_task.required_host = 'host'
                merged_task.required_host = 'host'
                assert merging_task.can_merge?(merged_task)
            end
            it "returns false if both tasks have a required host and it differs" do
                merging_task.required_host = 'host'
                merged_task.required_host = 'other_host'
                assert !merging_task.can_merge?(merged_task)
            end
        end

        stub_process_server_deployment_helpers = Module.new do
            attr_reader :deployment_m, :deployment0, :deployment1
            def setup
                super
                @deployment_m = Deployment.new_submodel
                @stub_process_servers = []
            end
            def teardown
                @stub_process_servers.each do |ps|
                    Syskit.conf.remove_process_server(ps.name)
                end
                super
            end

            def create_task_from_host_id(host_id, name: flexmock)
                process_server = RobyApp::UnmanagedTasksManager.new
                process = RobyApp::UnmanagedProcess.new(process_server, 'test', nil)
                log_dir = flexmock('log_dir')
                process_server_config =
                    Syskit.conf.register_process_server(name, process_server, log_dir, host_id: host_id)
                @stub_process_servers << process_server_config
                deployment = deployment_m.new(on: name)
                plan.add(task = task_m.new)
                task.executed_by(deployment)
                task
            end
        end

        describe "#distance_to_syskit" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns D_SAME_PROCESS if the task is on the 'syskit' host_id" do
                task = create_task_from_host_id 'syskit'
                assert_equal TaskContext::D_SAME_PROCESS, task.distance_to_syskit
            end
            it "returns D_SAME_HOST if the task is running on localhost" do
                task = create_task_from_host_id 'localhost'
                assert_equal TaskContext::D_SAME_HOST, task.distance_to_syskit
            end
            it "returns D_DIFFERENT_HOSTS if the task is not running on syskit or localhost" do
                task = create_task_from_host_id 'test'
                assert_equal TaskContext::D_DIFFERENT_HOSTS, task.distance_to_syskit
            end
        end

        describe "#in_process" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns true if the task is on the 'syskit' host_id" do
                assert create_task_from_host_id('syskit').in_process?
            end
            it "returns false if the task is running on localhost" do
                refute create_task_from_host_id('localhost').in_process?
            end
            it "returns false if the task is running on any other host_id than syskit and localhost" do
                refute create_task_from_host_id('test').in_process?
            end
        end

        describe "#on_localhost" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns true if the task is on the 'syskit' host_id" do
                assert create_task_from_host_id('syskit').on_localhost?
            end
            it "returns true if the task is running on localhost" do
                assert create_task_from_host_id('localhost').on_localhost?
            end
            it "returns false if the task is running on any other host_id than syskit and localhost" do
                refute create_task_from_host_id('test').on_localhost?
            end
        end

        describe "#distance_to" do
            include stub_process_server_deployment_helpers

            attr_reader :task_m, :deployment_m
            before do
                @task_m = TaskContext.new_submodel
                @deployment_m = Deployment.new_submodel
            end
            it "returns D_SAME_PROCESS if both tasks are identical" do
                task = create_task_from_host_id 'test'
                assert_equal TaskContext::D_SAME_PROCESS, task.distance_to(task)
            end
            it "returns D_SAME_PROCESS if both tasks are from the same process" do
                task0 = create_task_from_host_id 'test'
                task1 = task_m.new
                task1.executed_by(task0.execution_agent)
                assert_equal TaskContext::D_SAME_PROCESS, task0.distance_to(task1)
            end
            it "returns D_SAME_HOST if both tasks are from processes on the same host" do
                task0 = create_task_from_host_id 'test'
                task1 = create_task_from_host_id 'test'
                assert_equal TaskContext::D_SAME_HOST, task0.distance_to(task1)
            end
            it "returns D_DIFFERENT_HOSTS if both tasks are from processes from different hosts" do
                task0 = create_task_from_host_id 'here'
                task1 = create_task_from_host_id 'there'
                assert_equal TaskContext::D_DIFFERENT_HOSTS, task0.distance_to(task1)
            end
            it "returns nil if one of the two tasks has no execution agent" do
                task0 = create_task_from_host_id 'here'
                plan.add(task = TaskContext.new_submodel.new)
                assert !task.distance_to(task0)
                assert !task0.distance_to(task)
            end
        end

        describe "#find_input_port" do
            attr_reader :task
            before do
                @task = syskit_stub_deploy_and_configure 'Task' do
                    input_port "in", "int"
                    output_port "out", "int"
                end
            end

            it "should return the port from #orocos_task if it exists" do
                Orocos.allow_blocking_calls do
                    assert_equal task.orocos_task.port("in"), task.find_input_port("in").to_orocos_port
                end
            end
            it "should return nil for an output port" do
                assert_nil task.find_input_port("out")
            end
            it "should return nil for a port that does not exist" do
                assert_nil task.find_input_port("does_not_exist")
            end
        end

        describe "#find_output_port" do
            attr_reader :task
            before do
                @task = syskit_stub_deploy_and_configure 'Task' do
                    input_port "in", "int"
                    output_port "out", "int"
                end
            end

            it "should return the port from #orocos_task if it exists" do
                Orocos.allow_blocking_calls do
                    assert_equal task.orocos_task.port("out"), task.find_output_port("out").to_orocos_port
                end
            end
            it "should return nil for an input port" do
                assert_nil task.find_output_port("in")
            end
            it "should return nil for a port that does not exist" do
                assert_nil task.find_output_port("does_not_exist")
            end
        end

        describe "start_event" do
            attr_reader :task, :task_m, :orocos_task
            before do
                @task_m = TaskContext.new_submodel do
                    input_port "in", "/double"
                    output_port "out", "/double"
                end
                task = syskit_stub_deploy_and_configure(task_m)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            after do
                if task.start_event.pending?
                    task.start_event.emit
                end
                if task.running?
                    messages = capture_log(task, :info) do
                        task.stop_event.emit 
                    end
                    assert_equal ["stopped #{task}"], messages
                end
            end

            def call_task_start_event
                messages = capture_log(task, :info) do
                    task.start!
                end
                assert_equal ["starting #{task}"], messages
            end

            def start_task
                assert_event_emission task.start_event do
                    call_task_start_event
                end
            end

            it "queues start for the underlying task" do
                orocos_task.should_receive(:start).once.pass_thru
                start_task
            end
            it "checks that all required output ports are present" do
                task.should_receive(:each_concrete_output_connection).
                    and_return([[port = Object.new]]).once
                orocos_task.should_receive(:port_names).and_return([port]).once
                start_task
            end
            it "raises Orocos::NotFound if some required output ports are not present" do
                plan.unmark_mission_task(task)
                task.should_receive(:each_concrete_output_connection).
                    and_return([[port = Object.new]]).once
                orocos_task.should_receive(:start).never
                call_task_start_event
                assert_task_fails_to_start(task, Roby::EmissionFailed, original_exception: Orocos::NotFound) do
                    process_events
                end
            end
            it "checks that all required input ports are present" do
                task.should_receive(:each_concrete_input_connection).
                    and_return([[nil, nil, port = Object.new, nil]])
                orocos_task.should_receive(:port_names).and_return([port]).once
                start_task
            end
            it "raises Orocos::NotFound if some required input ports are not present" do
                plan.unmark_mission_task(task)
                task.should_receive(:each_concrete_input_connection).
                    and_return([[nil, nil, port = Object.new, nil]])
                orocos_task.should_receive(:port_names).once.and_return([])
                orocos_task.should_receive(:start).never
                call_task_start_event
                assert_task_fails_to_start(task, Roby::EmissionFailed, original_exception: Orocos::NotFound) do
                    process_events
                end
            end
            it "emits the start event once the state reader reported the RUNNING state" do
                FlexMock.use(task.state_reader) do |state_reader|
                    state = nil
                    state_reader.should_receive(:read_new).
                        and_return { s, state = state, nil; s }
                    call_task_start_event
                    process_events
                    assert !task.running?
                    state = :RUNNING
                    assert_event_emission task.start_event
                end
            end
            it "fails to start if orocos_task#start raises an exception" do
                plan.unmark_mission_task(task)
                error_m = Class.new(RuntimeError)
                orocos_task.should_receive(:start).once.and_raise(error_m)
                call_task_start_event
                assert_task_fails_to_start task, Roby::EmissionFailed, original_exception: error_m do
                    process_events
                end
            end
        end

        describe "#state_event" do
            it "should be able to resolve events from parent models" do
                parent_m = TaskContext.new_submodel do
                    runtime_states :CUSTOM
                end
                child_m = parent_m.new_submodel
                child = child_m.new
                assert_equal :custom, child.state_event(:CUSTOM)
            end
        end

        describe "stop_event" do
            attr_reader :task, :orocos_task
            before do
                @task = syskit_stub_deploy_configure_and_start(TaskContext.new_submodel)
                @orocos_task = flexmock(task.orocos_task)
            end

            it "is not emitted by the interruption command" do
                task.stop!
                assert !task.stop_event.emitted?
                assert task.finishing?
            end
            it "emits interrupt and aborted if orocos_task#stop raises ComError" do
                orocos_task.should_receive(:stop).and_raise(Orocos::ComError)
                plan.unmark_mission_task(task)
                assert_event_emission task.aborted_event do
                    task.stop!
                end
                assert task.interrupt_event.emitted?
            end
            it "emits interrupt if orocos_task#stop raises StateTransitionFailed but the task is in a stopped state" do
                task.orocos_task.should_receive(:stop).and_return do
                    Orocos::TaskContext.instance_method(:stop).call(task.orocos_task, false)
                    raise Orocos::StateTransitionFailed
                end
                plan.unmark_mission_task(task)
                assert_event_emission task.interrupt_event do
                    task.stop!
                end
            end
            it "is stopped when the stop event is received" do
                plan.unmark_mission_task(task)
                assert_event_emission task.stop_event do
                    task.stop!
                end
            end
        end

        describe "#handle_state_changes" do
            attr_reader :task, :task_m, :orocos_task
            before do
                @task_m = TaskContext.new_submodel do
                    input_port "in", "/double"
                    output_port "out", "/double"
                    reports :blabla

                    event :test
                end
                task = syskit_stub_deploy_and_configure(task_m)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            after do
                if task.start_event.pending?
                    task.start_event.emit
                end
                if task.running?
                    messages = capture_log(task, :info) do
                        task.stop_event.emit 
                    end
                    assert_equal ["stopped #{task}"], messages
                end
            end

            it "does nothing if no runtime state has been received" do
                task.should_receive(:orogen_state).and_return(:exception)
                orocos_task.should_receive(:runtime_state?).with(:exception).and_return(false)
                task.handle_state_changes
                process_events
                assert !task.running?
            end
            it "emits start as soon as a runtime state has been received, and emits the event mapped by #state_event" do
                task.should_receive(:orogen_state).and_return(:blabla)
                orocos_task.should_receive(:runtime_state?).with(:blabla).and_return(true)
                task.should_receive(:state_event).with(:blabla).and_return(:test)
                assert_event_emission task.start_event do
                    task.handle_state_changes
                end
                assert task.test_event.emitted?
            end
            it "raises ArgumentError if the state cannot be mapped to an event" do
                syskit_start(task)
                task.should_receive(:orogen_state).and_return(:blabla)
                task.should_receive(:state_event).and_return(nil)
                e = assert_raises(ArgumentError) do
                    task.handle_state_changes
                end
                assert_equal "#{task} reports state blabla, but I don't have an event for this state transition", e.message
            end
            it "emits the 'running' event when transitioning out of an error state" do
                syskit_start(task)
                task.should_receive(:last_orogen_state).and_return(:BLA)
                orocos_task.should_receive(:error_state?).with(:BLA).once.and_return(true)
                assert_event_emission task.running_event do
                    task.handle_state_changes
                end
                assert_equal 2, task.running_event.history.size
            end
            it "does not emit the 'running' event if the last state was not an error state" do
                syskit_start(task)
                task.should_receive(:last_orogen_state).and_return(:BLA)
                orocos_task.should_receive(:error_state?).with(:BLA).once.and_return(false)
                task.handle_state_changes
                process_events
                assert_equal 1, task.running_event.history.size
            end
        end

        describe "#update_orogen_state" do
            attr_reader :task, :orocos_task
            before do
                task_m = TaskContext.new_submodel
                task = syskit_stub_and_deploy(task_m)
                @task = flexmock(task)
                syskit_start_execution_agents(task)
                @orocos_task = flexmock(task.orocos_task)
                flexmock(task.state_reader)
            end

            it "is provided a connected state reader by its execution agent" do
                syskit_start_execution_agents(task)
                assert task.state_reader.connected?
            end
            it "emits :aborted if the state reader got disconnected" do
                task = syskit_stub_deploy_configure_and_start(TaskContext.new_submodel)
                setting_up = task.instance_variable_get(:@setting_up)
                assert(!setting_up || setting_up.complete?)
                task.update_orogen_state
                Orocos.allow_blocking_calls do
                    task.state_reader.disconnect
                end
                orocos_task = task.orocos_task

                plan.add_permanent_task(task.execution_agent)
                plan.unmark_mission_task(task)
                assert_event_emission task.aborted_event do
                    task.update_orogen_state
                end
                Orocos.allow_blocking_calls do
                    assert_equal :STOPPED, orocos_task.rtt_state
                end
            end
            it "sets orogen_state with the new state" do
                task.state_reader.should_receive(:read_new).and_return(state = Object.new)
                task.update_orogen_state
                assert_equal state, task.orogen_state
            end
            it "updates last_orogen_state with the current state" do
                task.state_reader.should_receive(:read_new).and_return(state = Object.new)
                task.should_receive(:orogen_state).and_return(last_state = Object.new)
                task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
            end
            it "returns nil if no new state has been received" do
                task.state_reader.should_receive(:read_new)
                assert !task.update_orogen_state
            end
            it "does not change the last and current states if no new states have been received" do
                task.state_reader.should_receive(:read_new).
                    and_return(last_state = Object.new).
                    and_return(state = Object.new).
                    and_return(nil)
                task.update_orogen_state
                task.update_orogen_state
                assert !task.update_orogen_state
                assert_equal last_state, task.last_orogen_state
                assert_equal state, task.orogen_state
            end
            it "returns the new state if there is one" do
                task.state_reader.should_receive(:read_new).and_return(state = Object.new)
                assert_equal state, task.update_orogen_state
            end
        end
        describe "#ready_for_setup?" do
            attr_reader :task, :orocos_task
            before do
                task = syskit_stub_deploy_and_configure('Task') {}
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
                task.state_getter.wait
            end

            it "returns true for a fully instanciated task whose state is PRE_OPERATIONAL" do
                assert task.ready_for_setup?
            end
            it "returns false if a task context representing the same component is being configured" do
                task = syskit_stub_and_deploy "ConcurrentConfigurationTask"
                syskit_start_execution_agents(task)
                plan.add_permanent_task(other_task = task.execution_agent.task(task.orocos_name))
                task.state_getter.wait
                promise = Syskit::Runtime.start_task_setup(other_task)
                task.state_getter.wait
                refute task.ready_for_setup?
                execution_engine.join_all_waiting_work
                assert task.ready_for_setup?
            end
            it "returns true if a task context representing the same component has started configuring and the configuration failed" do
                task = syskit_stub_and_deploy "ConcurrentConfigurationTask"
                syskit_start_execution_agents(task)
                plan.add(other_task = task.execution_agent.task(task.orocos_name))
                assert task.ready_for_setup?
                flexmock(other_task.orocos_task).should_receive(:configure).and_raise(Orocos::StateTransitionFailed)
                promise = Syskit::Runtime.start_task_setup(other_task)
                task.state_getter.wait
                refute task.ready_for_setup?
                execution_engine.join_all_waiting_work
                assert task.ready_for_setup?
            end
            it "returns false if the task has been marked as garbage" do
                task.garbage!
                refute task.ready_for_setup?
            end
            it "returns false if task arguments are not set" do
                task.should_receive(:fully_instanciated?).and_return(false)
                refute task.ready_for_setup?
            end
            it "returns false if the task has no orogen model yet" do
                task.should_receive(:orogen_model)
                refute task.ready_for_setup?
            end
            it "returns false if the task has no orocos task yet" do
                task.should_receive(:orocos_task)
                refute task.ready_for_setup?
            end
            it "returns false if the task's current state cannot be read" do
                task.should_receive(:read_current_state).and_return(nil)
                refute task.ready_for_setup?
            end
            it "returns false if the task's current state is not one from which we can configure" do
                task.should_receive(:read_current_state).and_return(state = Object.new)
                refute task.ready_for_setup?
            end
            it "returns true if the task's current state is an exception state" do
                task.should_receive(:read_current_state).and_return(state = Object.new)
                flexmock(task.orocos_task).should_receive(:exception_state?).
                    with(state).and_return(true)
                assert task.ready_for_setup?
            end
            it "returns true if the task's current state is STOPPED" do
                task.should_receive(:read_current_state).and_return(:STOPPED)
                assert task.ready_for_setup?
            end
            it "returns true if the task's current state is PRE_OPERATIONAL" do
                task.should_receive(:read_current_state).and_return(:STOPPED)
                assert task.ready_for_setup?
            end
        end

        describe "#read_current_state" do
            attr_reader :task, :state_getter
            before do
                @task = syskit_stub_and_deploy('Task') do
                    runtime_states :CUSTOM
                end
                syskit_start_execution_agents(task)
                @state_getter = flexmock(task.state_getter)
            end
            it "returns nil if both #read and #read_new return nil" do
                state_getter.should_receive(:read_new).and_return(nil).once
                state_getter.should_receive(:read).and_return(nil).once
                assert_nil task.read_current_state
            end
            it "returns the value of the last non-nil #read_new" do
                state_getter.should_receive(:read_new).and_return(1, 2, 3, nil)
                assert_equal 3, task.read_current_state
            end
            it "returns the value of #read if #read_new returns nil" do
                state_getter.should_receive(:read_new).and_return(nil)
                state_getter.should_receive(:read).and_return(3)
                assert_equal 3, task.read_current_state
            end
            it "issues a fatal message if the status returned by the state getter and by the state reader differ" do
                state_reader = flexmock
                flexmock(task).should_receive(state_reader: state_reader)
                state_reader.should_receive(:read_new).and_return(:CUSTOM, nil)
                state_getter.should_receive(:read_new).and_return(:STOPPED, nil)
                flexmock(task).should_receive(:fatal).once.
                    with("state reader of #{task} reports the CUSTOM state which does not match STOPPED, reported by the remote getter")
                assert_equal :STOPPED, task.read_current_state
            end
        end

        describe "#setup_successful!" do
            attr_reader :task
            before do
                plan.add(task = TaskContext.new_submodel.new(orocos_name: "", conf: []))
                @task = flexmock(task)
                assert !task.executable?
            end
            it "resets the executable flag if all inputs are connected" do
                task.should_receive(:all_inputs_connected?).and_return(true).once
                task.setup_successful!
                assert task.executable?
            end
            it "does not reset the executable flag if some inputs are not connected" do
                task.should_receive(:all_inputs_connected?).and_return(false).once
                task.setup_successful!
                assert !task.executable?
            end
        end
        describe "#reusable?" do
            it "is false if the task is setup and needs reconfiguration" do
                task = flexmock(TaskContext.new_submodel.new)
                assert task.reusable?
                task.should_receive(:setup?).and_return(true)
                task.should_receive(:needs_reconfiguration?).and_return(true)
                assert !task.reusable?
            end
        end
        describe "needs_reconfiguration" do
            attr_reader :task_m
            before do
                @task_m = TaskContext.new_submodel
            end
            it "sets the reconfiguration flag to true for a given orocos name" do
                t0 = task_m.new(orocos_name: "bla")
                t1 = task_m.new(orocos_name: "bla")
                t0.needs_reconfiguration!
                assert t1.needs_reconfiguration?
            end
            it "does not set the flag for tasks of the same model but different names" do
                t0 = task_m.new(orocos_name: "bla")
                t1 = task_m.new(orocos_name: "other")
                t0.needs_reconfiguration!
                assert !t1.needs_reconfiguration?
            end
        end
        describe "#clean_dynamic_port_connections" do
            it "removes connections that relate to the task's dynamic input ports" do
                srv_m = DataService.new_submodel { input_port 'p', '/double' }
                task_m = TaskContext.new_submodel do
                    orogen_model.dynamic_input_port /.*/, '/double'
                end
                task_m.dynamic_service srv_m, as: 'test' do
                    provides srv_m, 'p' => "dynamic"
                end
                task = syskit_stub_deploy_and_configure task_m
                task.require_dynamic_service 'test', as: 'test'
                source_task = syskit_stub_deploy_and_configure 'SourceTask', as: 'source_task' do
                    input_port "dynamic", "/double"
                end
                orocos_tasks = [source_task.orocos_task, task.orocos_task]

                ActualDataFlow.add_connections(*orocos_tasks, Hash[['dynamic', 'dynamic'] => [Hash.new, false, false]])
                assert ActualDataFlow.has_edge?(*orocos_tasks)
                task.clean_dynamic_port_connections([])
                assert !ActualDataFlow.has_edge?(*orocos_tasks)
            end
            it "removes connections that relate to the task's dynamic output ports" do
                srv_m = DataService.new_submodel { output_port 'p', '/double' }
                task_m = TaskContext.new_submodel do
                    orogen_model.dynamic_output_port /.*/, '/double'
                end
                task_m.dynamic_service srv_m, as: 'test' do
                    provides srv_m, 'p' => "dynamic"
                end
                task = syskit_stub_deploy_and_configure task_m
                task.require_dynamic_service 'test', as: 'test'

                sink_task = syskit_stub_deploy_and_configure 'SinkTask', as: 'sink_task' do
                    output_port "dynamic", "/double"
                end
                orocos_tasks = [task.orocos_task, sink_task.orocos_task]

                ActualDataFlow.add_connections(*orocos_tasks, Hash[['dynamic', 'dynamic'] => [Hash.new, false, false]])
                assert ActualDataFlow.has_edge?(*orocos_tasks)
                task.clean_dynamic_port_connections([])
                assert !ActualDataFlow.has_edge?(*orocos_tasks)
            end
        end

        describe "#prepare_for_setup" do
            attr_reader :task, :orocos_task
            before do
                task_m = TaskContext.new_submodel
                task = syskit_stub_deploy_and_configure(task_m, as: 'task')
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            def prepare_task_for_setup(rtt_state)
                recorder = flexmock
                recorder.should_receive(:called).once.ordered
                flexmock(task.orocos_task).should_receive(:rtt_state).and_return(rtt_state)
                promise = execution_engine.promise(description: "#{name}#prepare_task_for_setup") { recorder.called }
                promise = task.prepare_for_setup(promise)
                promise.execute
                execution_engine.join_all_waiting_work
                promise.value!
            end

            it "resets an exception state" do
                orocos_task.should_receive(:reset_exception).once.ordered
                task.should_receive(:clean_dynamic_port_connections).once.ordered
                messages = capture_log(task, :info) do
                    prepare_task_for_setup(:EXCEPTION)
                end
                assert messages.include?("reconfiguring #{task}: the task was in exception state")
            end
            it "does nothing if the state is PRE_OPERATIONAL" do
                messages = capture_log(task, :info) do
                    prepare_task_for_setup(:PRE_OPERATIONAL)
                end
                assert_equal ["not reconfiguring #{task}: the task is already configured as required"],
                    messages
                task.should_receive(:clean_dynamic_port_connections).never
            end
            it "does nothing if the state is STOPPED and the task does not need to be reconfigured" do
                TaskContext.configured['task'] = [nil, ['default'], Set.new]
                orocos_task.should_receive(:cleanup).never
                task.should_receive(:clean_dynamic_port_connections).never
                messages = capture_log(task, :info) do
                    prepare_task_for_setup(:STOPPED)
                end
                assert_equal ["not reconfiguring #{task}: the task is already configured as required"],
                    messages
            end
            it "cleans up if the state is STOPPED and the task is marked as requiring reconfiguration" do
                task.should_receive(:needs_reconfiguration?).and_return(true)
                orocos_task.should_receive(:cleanup).once.ordered
                task.should_receive(:clean_dynamic_port_connections).once.ordered
                messages = capture_log(task, :info) do
                    prepare_task_for_setup(:STOPPED)
                end
                assert_equal ["cleaning up #{task}"],
                    messages
            end
            it "cleans up if the state is STOPPED and the task has never been configured" do
                TaskContext.configured[task.orocos_name] = nil
                orocos_task.should_receive(:cleanup).once.ordered
                task.should_receive(:clean_dynamic_port_connections).once.ordered
                messages = capture_log(task, :info) do
                    prepare_task_for_setup(:STOPPED)
                end
                assert_equal ["cleaning up #{task}"], messages
            end
            it "cleans up if the state is STOPPED and the task's configuration changed" do
                TaskContext.configured[task.orocos_name] = [nil, [], Set.new]
                orocos_task.should_receive(:cleanup).once.ordered
                task.should_receive(:clean_dynamic_port_connections).once.ordered
                messages = capture_log(task, :info) do
                    prepare_task_for_setup(:STOPPED)
                end
                assert_equal ["cleaning up #{task}"], messages
            end
        end
        describe "#setup" do
            attr_reader :task, :orocos_task, :recorder
            before do
                @recorder = flexmock
                recorder.should_receive(:called)
                recorder.should_receive(:error).never.by_default
                task = syskit_stub_and_deploy 'Task', as: 'task' do
                    input_port "in", "int"
                    output_port "out", "int"
                end
                syskit_start_execution_agents(task, recursive: true)
                @task = flexmock(task)
                @orocos_task = flexmock(task.orocos_task)
            end

            def default_setup_task_messages(task)
                ["applied configuration [\"default\"] to #{task.orocos_name}", "setting up #{task}"]
            end

            def setup_task(task = self.task, expected_messages: nil)
                promise = nil
                messages = capture_log(task, :info) do
                    promise = Runtime.start_task_setup(task)
                    execution_engine.join_all_waiting_work
                end
                if !expected_messages
                    expected_messages = default_setup_task_messages(task)
                end
                assert_equal expected_messages, messages
                promise.value!
            end

            it "freezes delayed arguments" do
                plan.remove_task(task)
                task = syskit_stub_network_deployment(TaskContext.new_submodel.new)
                plan.add_permanent_task(task)
                syskit_start_execution_agents(task)
                assert_nil task.arguments[:conf]
                setup_task(task)
                assert_equal ['default'], task.arguments[:conf]
            end

            it "resets the needs_configuration flag" do
                orocos_task.should_receive(:rtt_state).and_return(:PRE_OPERATIONAL)
                task.should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
                task.needs_reconfiguration!
                setup_task
                assert !task.needs_reconfiguration?
            end
            it "registers the current task configuration" do
                orocos_task.should_receive(:rtt_state).and_return(:PRE_OPERATIONAL)
                task.should_receive(:ready_for_setup?).with(:PRE_OPERATIONAL).and_return(true)
                task.needs_reconfiguration!
                setup_task
                assert_equal ['default'], TaskContext.configured[task.orocos_name][1]
            end
            it "reports an exception from the user-provided #configure method as failed-to-start" do
                plan.unmark_mission_task(task)
                task.should_receive(:configure).and_raise(error_e = Class.new(RuntimeError))
                assert_task_fails_to_start(task, Roby::EmissionFailed, original_exception: error_e) do
                    assert_raises(error_e) do
                        setup_task(expected_messages: [])
                    end
                end
                assert task.failed_to_start?
            end
            it "keeps the task in the plan until the asynchronous setup is finished" do
                plan.unmark_mission_task(task)
                process_events_until(join_all_waiting_work: false, garbage_collect_pass: true) do
                    task.setup?
                end
            end
            it "keeps the task in the plan until the asynchronous setup's error has been handled" do
                flexmock(task).should_receive(:configure).and_return do
                    sleep 0.1
                    raise RuntimeError
                end
                plan.unmark_mission_task(task)
                flexmock(task.start_event).should_receive(:emit_failed).
                    pass_thru do |ret|
                        refute task.can_finalize?
                        ret
                    end

                process_events_until(join_all_waiting_work: false, garbage_collect_pass: true) do
                    task.failed_to_start?
                end
            end
            describe "ordering related to prepare_for_setup" do
                attr_reader :error_m

                before do
                    @error_m = Class.new(RuntimeError)
                    promise = execution_engine.promise(description: "#{name}#before") { recorder.called }
                    task.should_receive(:prepare_for_setup).once.
                        and_return(promise)
                end

                it "calls the user-provided #configure method after prepare_for_setup" do
                    task.should_receive(:configure).once.ordered
                    setup_task(expected_messages: ["setting up #{task}"])
                end
                it "calls the task's configure method if the task's state is PRE_OPERATIONAL" do
                    orocos_task.should_receive(:rtt_state).and_return(:PRE_OPERATIONAL)
                    orocos_task.should_receive(:configure).once.ordered
                    setup_task(expected_messages: ["applied configuration [\"default\"] to #{task.orocos_name}", "setting up #{task}"])
                end
                it "does not call the task's configure method if the task's state is not PRE_OPERATIONAL" do
                    orocos_task.should_receive(:rtt_state).and_return(:STOPPED)
                    orocos_task.should_receive(:configure).never
                    setup_task(expected_messages: ["applied configuration [\"default\"] to #{task.orocos_name}", "#{task} was already configured"])
                end
                it "does not call setup_successful!" do
                    task.should_receive(:setup_successful!).never
                    messages = capture_log(task, :info) do
                        promise = execution_engine.promise(description: "setup of #{task}") { }
                        promise = task.setup(promise)
                        promise.execute
                        execution_engine.join_all_waiting_work
                        promise.value!
                    end
                    assert_equal default_setup_task_messages(task), messages
                end
                it "does not call the task's configure method if the user-provided configure method raises" do
                    plan.unmark_mission_task(task)
                    task.should_receive(:configure).and_raise(error_m)
                    orocos_task.should_receive(:configure).never
                    assert_task_fails_to_start(task, Roby::EmissionFailed, original_exception: error_m) do
                        assert_raises(error_m) do
                            setup_task(expected_messages: [])
                        end
                    end
                end
            end
        end
        describe "#configure" do
            it "applies the selected configuration" do
                task_m = TaskContext.new_submodel name: 'Task' do
                    property 'v', '/int'
                end
                task = syskit_stub_and_deploy(task_m.with_conf('my', 'conf'))
                flexmock(task.model.configuration_manager).should_receive(:conf).
                    with(['my', 'conf'], true).
                    once.
                    and_return('v' => 10)
                syskit_configure(task)
                Orocos.allow_blocking_calls do
                    assert_equal 10, task.orocos_task.v
                end
            end
        end

        describe "interrupt_event" do
            attr_reader :task, :orocos_task, :deployment
            it "calls stop on the task if it has an execution agent in nominal state" do
                task = syskit_stub_deploy_configure_and_start(TaskContext.new_submodel)
                flexmock(task.orocos_task).should_receive(:stop).once.pass_thru
                task.interrupt!
                plan.unmark_mission_task(task)
                assert_event_emission task.stop_event
            end
        end

        describe "#deployment_hints" do
            describe "the behaviour for device drivers" do
                let(:component_hint) { flexmock }
                let(:device_hint) { flexmock }
                let(:task) do
                    device_m = Device.new_submodel
                    task_m = TaskContext.new_submodel
                    task_m.driver_for device_m, as: 'test'
                    dev = robot.device(device_m, as: 'test').prefer_deployed_tasks(device_hint)
                    task_m.new("test_dev" => dev)
                end

                it "uses the hints from its own requirements if there are some" do
                    task.requirements.deployment_hints << component_hint
                    assert_equal [component_hint], task.deployment_hints.to_a
                end

                it "uses the hints from its attached devices if there are none in the requirements" do
                    assert_equal [device_hint], task.deployment_hints.to_a
                end
            end
        end

        it "should synchronize the startup of communication busses and their supported devices" do
            combus_m = ComBus.new_submodel message_type: '/int'
            combus_driver_m = TaskContext.new_submodel(name: 'BusDriver') do
                dynamic_output_port /.*/, '/int'
            end
            combus_driver_m.provides combus_m, as: 'driver'
            device_m = Device.new_submodel
            device_driver_m = TaskContext.new_submodel(name: 'Driver') do
                input_port 'bus_in', '/int'
            end
            device_driver_m.provides combus_m.client_in_srv, as: 'bus'
            device_driver_m.provides device_m, as: 'driver'

            bus = robot.com_bus combus_m, as: 'bus'
            dev = robot.device device_m, as: 'dev'
            dev.attach_to(bus, client_to_bus: false)

            execution_engine.scheduler.enabled = false

            # Now, deploy !
            syskit_stub_deployment_model(combus_driver_m, 'bus_task', remote_task: false)
            syskit_stub_deployment_model(device_driver_m, 'dev_task')
            dev_driver = syskit_deploy(dev)
            bus_driver = plan.find_tasks(combus_driver_m).first
            syskit_start_execution_agents(bus_driver)
            syskit_start_execution_agents(dev_driver)

            mock_logger = flexmock(:level= => nil, :level => Logger::INFO, :debug => nil)
            bus_driver.logger = dev_driver.logger = mock_logger
            messages = capture_log(mock_logger, :info) do
                bus_driver.orocos_task.create_output_port 'dev', '/int'
                flexmock(bus_driver.orocos_task, "bus").should_receive(:start).once.globally.ordered(:setup).pass_thru
                mock_raw_port(bus_driver.orocos_task, 'dev').should_receive(:connect_to).once.globally.ordered(:setup).pass_thru
                flexmock(dev_driver.orocos_task, "dev").should_receive(:start).once.globally.ordered.pass_thru
                execution_engine.scheduler.enabled = true
                assert_event_emission bus_driver.start_event
                assert_event_emission dev_driver.start_event
            end
            assert_equal ["applied configuration [\"default\"] to #{bus_driver.orocos_name}",
                          "setting up #{bus_driver}",
                          "starting #{bus_driver}",
                          "applied configuration [\"default\"] to #{dev_driver.orocos_name}",
                          "setting up #{dev_driver}",
                          "starting #{dev_driver}"], messages
        end

        describe "#transaction_modifies_static_ports?" do
            def self.handling_of_static_ports(input: false)
                attr_reader :transaction
                attr_reader :source_task, :sink_task
                before do
                    @source_task = syskit_stub_and_deploy "SourceTask", as: 'source_task' do
                        p = output_port('out', 'int')
                        p.static if !input
                    end
                    @sink_task = syskit_stub_and_deploy "Task" do
                        p = input_port('in', 'int')
                        p.static if input
                    end
                    @transaction = create_transaction
                end

                let(:sink_task_p) { transaction[sink_task] }
                let(:source_task_p) { transaction[source_task] }
                let(:task_p) do
                    if input then sink_task_p
                    else source_task_p
                    end
                end

                def configure_tasks
                    syskit_configure(source_task)
                    syskit_configure(sink_task)
                    Runtime::ConnectionManagement.update(plan)
                end

                it "returns true if the transaction adds a connections to a static port" do
                    configure_tasks
                    source_task_p.out_port.connect_to sink_task_p.in_port
                    assert task_p.transaction_modifies_static_ports?
                end
                it "returns false if an unconnected port stays unconnected" do
                    configure_tasks
                    source_task_p; sink_task_p # ensure both tasks are in the transaction
                    assert !task_p.transaction_modifies_static_ports?
                end
                it "returns false if a connected port stays the same" do
                    source_task.out_port.connect_to sink_task.in_port
                    configure_tasks
                    source_task_p; sink_task_p # ensure both tasks are in the transaction
                    assert !task_p.transaction_modifies_static_ports?
                end
                it "returns true if the transaction removes a connections to a static port" do
                    source_task.out_port.connect_to sink_task.in_port
                    configure_tasks
                    source_task_p.out_port.disconnect_from sink_task_p.in_port
                    assert task_p.transaction_modifies_static_ports?
                end

            end


            describe "handling of static input ports" do
                handling_of_static_ports(input: true)

                it "returns true if a static input port is connected to new tasks" do
                    configure_tasks
                    transaction.add(new_task = source_task.model.new)
                    new_task.out_port.connect_to sink_task_p.in_port
                    assert sink_task_p.transaction_modifies_static_ports?
                end

                it "uses concrete input connections to determine the new connections" do
                    cmp_m = Composition.new_submodel
                    cmp_m.add source_task.model, as: 'test'
                    cmp_m.export cmp_m.test_child.out_port, as: 'out'
                    cmp = syskit_stub_and_deploy(cmp_m.use('test' => source_task))

                    cmp.out_port.connect_to sink_task.in_port
                    configure_tasks
                    new_cmp = cmp_m.use('test' => source_task_p).instanciate(transaction)
                    cmp_p = transaction[cmp]
                    cmp_p.out_port.disconnect_from sink_task_p.in_port
                    new_cmp.out_port.connect_to sink_task_p.in_port
                    assert !sink_task_p.transaction_modifies_static_ports?
                end
            end
            describe "handling of static output ports" do
                handling_of_static_ports(input: false)

                it "returns true if a static output port is connected to new tasks" do
                    configure_tasks
                    transaction.add(new_task = sink_task.model.new)
                    source_task_p.out_port.connect_to new_task.in_port
                    assert source_task_p.transaction_modifies_static_ports?
                end

                it "uses concrete output connections to determine the new connections" do
                    cmp_m = Composition.new_submodel
                    cmp_m.add sink_task.model, as: 'test'
                    cmp_m.export cmp_m.test_child.in_port, as: 'in'
                    cmp = syskit_stub_and_deploy(cmp_m.use('test' => sink_task))

                    source_task.out_port.connect_to cmp.in_port
                    configure_tasks
                    new_cmp = cmp_m.use('test' => sink_task_p).instanciate(transaction)
                    cmp_p = transaction[cmp]
                    source_task.out_port.disconnect_from cmp.in_port
                    source_task_p.out_port.connect_to new_cmp.in_port
                    assert !source_task_p.transaction_modifies_static_ports?
                end
            end
        end

        describe "specialized models" do
            it "has an isolated orogen model" do
                task_m = TaskContext.new_submodel
                task   = task_m.new
                assert_same task.model.orogen_model, task_m.orogen_model
                task.specialize
                assert_same task.model.orogen_model.superclass, task_m.orogen_model
                task.model.orogen_model.output_port 'p', '/double'
                assert !task_m.orogen_model.has_port?('p')
                assert task.model.orogen_model.has_port?('p')
            end
        end

        describe "property handling" do
            attr_reader :double_t, :task_m, :task
            before do
                @double_t = double_t = stub_type '/double'
                @task_m = TaskContext.new_submodel do
                    property 'test', double_t
                end
                @task = task_m.new
            end

            it "creates all properties at initialization time" do
                assert(p = task.property('test'))
                assert_equal 'test', p.name
                assert_same double_t, p.type
            end

            it "uses the intermediate type as property type" do
                intermediate_t = stub_type '/intermediate'
                flexmock(Roby.app.default_loader).should_receive(:intermediate_type_for).
                    with(double_t).and_return(intermediate_t)
                task = task_m.new
                assert_same intermediate_t, task.property('test').type
            end

            describe "#has_property?" do
                it "returns true if the property exists" do
                    assert task.has_property?('test')
                end
                it "returns false if the property does not exist" do
                    refute task.has_property?('does_not_exist')
                end
            end

            describe "#property" do
                it "returns the property object" do
                    assert(p = task.property('test'))
                    assert_kind_of Property, p
                    assert_equal task, p.task_context
                    assert_equal 'test', p.name
                    assert_same double_t, p.type
                end
                it "accepts a symbol as argument" do # backward compatibility with orocos.rb
                    assert task.property(:test)
                end
                it "raises Orocos::InterfaceObjectNotFound if the property does not exist" do
                    assert_raises(Orocos::InterfaceObjectNotFound) do
                        task.property('does_not_exist')
                    end
                end

                describe "property access through method_missing" do
                    it "returns the property when called with its name suffixed with _property" do
                        assert_equal task.property('test'), task.test_property
                    end
                    it "raises NoMethodError if the property does not exist" do
                        exception = assert_raises(NoMethodError) do
                            task.does_not_exist_property
                        end
                        assert_equal "#{task} has no property named does_not_exist", exception.message
                    end
                    it "does follow-up method resolution if the name does not end with _property" do
                        stub_t = stub_type '/test'
                        task_m = TaskContext.new_submodel { output_port 'port_test', stub_t }
                        task = task_m.new
                        assert_equal task.find_port('port_test'), task.port_test_port
                    end
                end
            end

            describe "#properties" do
                it "gives read/write access to the properties as fields" do
                    task.properties.test = 10
                    assert_equal 10, task.properties.test
                end

                it "gives read/write access to the raw typelib values" do
                    raw_value = Typelib.from_ruby(10, task.test_property.type)
                    task.properties.raw_test = raw_value
                    assert_equal raw_value, task.properties.raw_test
                end

                it "raises NotFound if the property does not exist" do
                    assert_raises(Orocos::NotFound) do
                        task.properties.does_not_exist
                    end
                end
            end

            describe "#each_property" do
                it "yields the properties" do
                    recorder = flexmock
                    test_p = task.property('test')
                    recorder.should_receive(:called).with(test_p).once
                    task.each_property { |p| recorder.called(p) }
                end
                it "returns an enumerator if called without a block" do
                    assert_equal [task.property('test')],
                        task.each_property.to_a
                end
            end

            describe "property updates at runtime" do
                attr_reader :task, :property
                before do
                    @task = syskit_stub_deploy_configure_and_start(task_m)
                    @property = task.test_property
                    Orocos.allow_blocking_calls do
                        @remote_test_property = task.orocos_task.raw_property('test')
                        @remote_test_property.write(0.2)
                    end
                end
                def mock_remote_property
                    task.property('test').remote_property = @remote_test_property
                    flexmock(@remote_test_property)
                end
                it "queues a property update" do
                    mock_remote_property.should_receive(:write).once.with(0.1)
                    property.write(0.1)
                    process_events
                end
                it "queues only one property update even in case of multiple writes" do
                    mock_remote_property.should_receive(:write).once.with(0.3)
                    property.write(0.1)
                    property.write(0.2)
                    property.write(0.3)
                    process_events
                end
                it "reports PropertyUpdateError on a failed write" do
                    error_m = Class.new(RuntimeError)
                    property.write(0.1)
                    mock_remote_property.should_receive(:write).once.
                        and_raise(error_m)
                    assert_fatal_exception(PropertyUpdateError, failure_point: task, original_exception: error_m, tasks: [task]) do
                        process_events
                    end
                end
            end


            describe "#commit_properties" do
                attr_reader :task, :stub_property, :remote_test_property
                before do
                    @task = syskit_stub_and_deploy(task_m)
                    syskit_start_execution_agents(task)
                    @stub_property = task.property('test')
                    Orocos.allow_blocking_calls do
                        @remote_test_property = task.orocos_task.raw_property('test')
                        remote_test_property.write(0.2)
                    end
                    @guard = syskit_guard_against_start_and_configure
                end
                def mock_remote_property
                    stub_property.remote_property = @remote_test_property
                    flexmock(@remote_test_property)
                end

                it "ignores properties for which #needs_commit? returns false" do
                    flexmock(stub_property).should_receive(:needs_commit?).and_return(false)
                    task.commit_properties.execute
                    flexmock(Orocos::Property).new_instances.should_receive(:write).never
                    execution_engine.join_all_waiting_work
                end

                it "writes the properties that have an explicit value" do
                    stub_property.write(0.1)
                    flexmock(stub_property).should_receive(:needs_commit?).and_return(true)
                    flexmock(Orocos::Property).new_instances.should_receive(:write).once.
                        with(Typelib.from_ruby(0.1, double_t)).
                        pass_thru
                    task.commit_properties.execute
                    process_events
                    Orocos.allow_blocking_calls do
                        assert_equal 0.1, remote_test_property.read
                    end
                end
                it "ignores properties whose remote and local values match" do
                    stub_property.update_remote_value(stub_property.value)
                    task.commit_properties.execute
                    flexmock(Orocos::Property).new_instances.should_receive(:write).never
                    execution_engine.join_all_waiting_work
                    Orocos.allow_blocking_calls do
                        assert_equal 0.2, remote_test_property.read
                    end
                end
                it "updates the property's #remote_value after it has been written" do
                    stub_property.write(0.1)
                    property = flexmock
                    property.should_receive(:write).once.
                        globally.ordered
                    stub_property.remote_property = property
                    flexmock(stub_property).should_receive(:update_remote_value).once.
                        globally.ordered.pass_thru
                    task.commit_properties.execute
                    process_events
                    assert_equal Typelib.from_ruby(0.1, double_t), stub_property.remote_value
                end
                it "updates the property's log after it has been written" do
                    stub_property.write(0.1)
                    mock_remote_property.should_receive(:write).once.
                        globally.ordered
                    flexmock(stub_property).should_receive(:update_log).once.
                        globally.ordered.pass_thru
                    task.commit_properties.execute
                    process_events
                end

                describe "the update during setup" do
                    it "reports PropertyUpdateError on a failed write" do
                        error_m = Class.new(RuntimeError)
                        stub_property.write(0.1)
                        mock_remote_property.should_receive(:write).once.
                            and_raise(error_m)
                        task.commit_properties.execute
                        assert_fatal_exception(PropertyUpdateError, failure_point: task, original_exception: error_m, tasks: [task]) do
                            process_events
                        end
                    end
                end

                describe "initial values" do
                    attr_reader :task
                    before do
                        task_m = Syskit::TaskContext.new_submodel do
                            property 'p', '/int'
                        end
                        flexmock(Orocos::TaskContext).new_instances.
                            should_receive(:property).with('p').
                            and_return(flexmock(name: 'p', raw_read: 20))
                        @task = syskit_stub_and_deploy(task_m)
                    end

                    it "updates the property's known remote value regardless of the property's current setup" do
                        task.property('p').write(10)
                        task.property('p').update_remote_value(10)
                        syskit_start_execution_agents(task)
                        assert 20, Typelib.to_ruby(task.property('p').remote_value)
                    end

                    it "leaves already set values" do
                        task.property('p').write(10)
                        syskit_start_execution_agents(task)
                        assert 10, Typelib.to_ruby(task.property('p').read)
                    end

                    it "initializes unset properties with the value read from the task" do
                        syskit_start_execution_agents(task)
                        assert 20, Typelib.to_ruby(task.property('p').read)
                    end
                end
            end

            describe "non-blocking characteristics" do
                attr_reader :barrier, :task

                before do
                    @barrier = Concurrent::CyclicBarrier.new(2)
                    @task = syskit_stub_and_deploy(Syskit::TaskContext.new_submodel)
                    syskit_start_execution_agents(task)
                end

                after do
                    barrier.wait(2)
                end

                def wait_for_synchronization(**options)
                    process_events_until(join_all_waiting_work: false, **options) do
                        barrier.number_waiting == 1
                    end
                end

                def assert_process_events_does_not_block
                    process_events(join_all_waiting_work: false)
                end

                it "does not block the event loop if the node's configure command blocks" do
                    flexmock(task.orocos_task).should_receive(:configure).once.
                        pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's start command blocks" do
                    flexmock(task.orocos_task).should_receive(:start).once.
                        pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(enable_scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's stop command blocks" do
                    syskit_configure_and_start(task)
                    plan.unmark_mission_task(task)
                    flexmock(task.orocos_task).should_receive(:stop).once.
                        pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(enable_scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's cleanup command blocks" do
                    Orocos.allow_blocking_calls { task.orocos_task.configure(false) }
                    flexmock(task.orocos_task).should_receive(:cleanup).once.
                        pass_thru { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(enable_scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
                it "does not block the event loop if the node's reset_exception command blocks" do
                    flexmock(task.orocos_task).should_receive(:rtt_state).
                        and_return(:EXCEPTION, :PRE_OPERATIONAL, :RUNNING)
                    flexmock(task.orocos_task).should_receive(:reset_exception).once.
                        and_return { barrier.wait }
                    capture_log(task, :info) do
                        wait_for_synchronization(enable_scheduler: true)
                        assert_process_events_does_not_block
                    end
                end
            end
        end
    end
end

