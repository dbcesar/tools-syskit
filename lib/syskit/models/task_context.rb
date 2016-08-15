# Module where all the OroGen task context models get registered
module OroGen
end

module Syskit
    module Models
        # This module contains the model-level API for the task context models
        #
        # It is used to extend every subclass of Syskit::TaskContext
        module TaskContext
            include Models::Component
            include Models::PortAccess
            include Models::OrogenBase

            # @return [String] path to the extension file that got loaded to
            #   extend this model
            attr_accessor :extension_file

            # Checks if a given component implementation needs to be stubbed
            def needs_stub?(component)
                super || component.orocos_task.kind_of?(Orocos::RubyTasks::StubTaskContext)
            end

            def clear_model
                super

                if name = self.name
                    return if name !~ /^OroGen::/
                    name = name.gsub(/^OroGen::/, '')
                    begin
                        if constant("::#{name}") == self
                            spacename = self.spacename.gsub(/^OroGen::/, '')
                            constant("::#{spacename}").send(:remove_const, basename)
                        end
                    rescue NameError
                        false
                    end
                end
            end

            # Generates a hash of oroGen-level state names to Roby-level event
            # names
            #
            # @return [{Symbol=>Symbol}]
            def make_state_events
                orogen_model.states.each do |name, type|
                    event_name = name.snakecase.downcase.to_sym
                    if type == :toplevel
                        event event_name, :terminal => (name == 'EXCEPTION' || name == 'FATAL_ERROR')
                    else
                        event event_name, :terminal => (type == :exception || type == :fatal_error)
                        if type == :fatal
                            forward event_name => :fatal_error
                        elsif type == :exception
                            forward event_name => :exception
                        elsif type == :error
                            forward event_name => :runtime_error
                        end
                    end

                    self.state_events[name.to_sym] = event_name
                end
            end

            # Creates a subclass of TaskContext that represents the given task
            # specification. The class is registered as
            # Roby::Orogen::ProjectName::ClassName.
            def define_from_orogen(orogen_model, register: false)
                if model = find_model_by_orogen(orogen_model) # already defined, probably because of dependencies
                    return model
                end

                superclass = orogen_model.superclass
                if !superclass # we are defining a root model
                    supermodel = self
                else
                    supermodel = find_model_by_orogen(superclass) ||
                        define_from_orogen(superclass, register: register)
                end
                klass = supermodel.new_submodel(orogen_model: orogen_model)

                if register && orogen_model.name
                    register_syskit_model_from_orogen_name(klass)
                end

                klass
            end

            # Translates an orogen task context model name into the syskit
            # equivalent
            #
            # @return [(String,String)] the namespace and class names
            def syskit_names_from_orogen_name(orogen_name)
                namespace, basename = orogen_name.split '::'
                return namespace.camelcase(:upper), basename.camelcase(:upper)
            end

            # Registers the given syskit model on the class hierarchy, using the
            # (camelized) orogen name as a basis
            #
            # If there is a constant clash, the model will not be registered but
            # its #name method will return the "right" value enclosed in <>
            #
            # @return [Boolean] true if the model could be registered and false
            # otherwise
            def register_syskit_model_from_orogen_name(model)
                orogen_model = model.orogen_model

                namespace, basename = syskit_names_from_orogen_name(orogen_model.name)
                if Roby.app.backward_compatible_naming?
                    register_syskit_model(Object, namespace, basename, model)
                end
                register_syskit_model(OroGen, namespace, basename, model)
            end

            def register_syskit_model(mod, namespace, basename, model)
                namespace =
                    if mod.const_defined_here?(namespace)
                        mod.const_get(namespace)
                    else 
                        mod.const_set(namespace, Module.new)
                    end

                if namespace.const_defined_here?(basename)
                    warn "there is already a constant with the name #{namespace.name}::#{basename}, I am not registering the model for #{orogen_model.name} there"
                    false
                else
                    namespace.const_set(basename, model)
                    true
                end
            end

            # [Orocos::Spec::TaskContext] The base oroGen model that all submodels need to subclass
            attribute(:orogen_model) { Models.create_orogen_task_context_model }

            # A state_name => event_name mapping that maps the component's
            # state names to the event names that should be emitted when it
            # enters a new state.
            inherited_attribute(:state_event, :state_events, :map => true) { Hash.new }

            # Create a new TaskContext model
            #
            # @option options [String] name (nil) forcefully set a name for the model.
            #   This is only useful for "anonymous" models, i.e. models that are
            #   never assigned in the Ruby constant hierarchy
            # @option options [Orocos::Spec::TaskContext, Orocos::ROS::Spec::Node] orogen_model (nil) the
            #   oroGen model that should be used. If not given, an empty model
            #   is created, possibly with the name given to the method as well.
            def new_submodel(options = Hash.new, &block)
                super
            end

            def apply_block(&block)
                evaluation = DataServiceModel::BlockInstanciator.new(self)
                evaluation.instance_eval(&block)
            end

            # @api private
            #
            # Method called internally by metaruby
            def setup_submodel(submodel, orogen_model: nil, orogen_model_name: nil, **options)
                if !orogen_model
                    orogen_model = self.orogen_model.class.new(Roby.app.default_orogen_project, orogen_model_name)
                    orogen_model.subclasses self.orogen_model
                end
                submodel.orogen_model = orogen_model

                super(submodel, **options)
                submodel.make_state_events
            end

            def worstcase_processing_time(value)
                orogen_model.worstcase_processing_time(value)
            end

            def each_event_port(&block)
                orogen_model.each_event_port(&block)
            end

            # Override this model's default configuration manager
            #
            # @see configuration_manager
            attr_writer :configuration_manager

            # Returns the configuration management object for this task model
            #
            # @return [TaskConfigurationManager]
            def configuration_manager
                if !@configuration_manager
                    if !concrete_model?
                        manager = concrete_model.configuration_manager
                    else
                        manager = TaskConfigurationManager.new(Roby.app, self)
                        manager.reload
                    end
                    @configuration_manager = manager
                end
                @configuration_manager
            end

            # Merge the service model into self
            #
            # This is mainly used during dynamic service instantiation, to
            # update the underlying ports and trigger model based on the
            # service's orogen model
            def merge_service_model(service_model, port_mappings)
                Syskit::Models.merge_orogen_task_context_models(
                    orogen_model, [service_model.orogen_model], port_mappings)
            end
        end
    end
end

