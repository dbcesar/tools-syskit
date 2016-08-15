module Syskit
    module Coordination
        module Models
            # Module providing the methods necessary to easily use the data
            # monitoring tables within a fault response table
            module FaultResponseTableExtension
                extend MetaRuby::Attributes

                UsedDataMonitoringTable = Struct.new :table, :arguments

                # @return [Array<Model<Coordination::DataMonitoringTable>]
                inherited_attribute(:data_monitoring_table, :data_monitoring_tables) { Array.new }

                # @overload data_monitoring_table { root root_model; ... }
                #   Defines a data monitoring table that is embedded in this
                #   fault response table. It is a shorthand for defining a
                #   separate table and calling {#use_data_monitoring_table}
                #
                # @overload data_monitoring_table
                #   Returns the data monitoring table embedded in this fault
                #   response table
                #
                # @return [Model<Coordination::DataMonitoringTable>]
                def data_monitoring_table(&block)
                    if !@embedded_table
                        table = Syskit::Coordination::DataMonitoringTable.new_submodel(&block)
                        arguments = Hash.new
                        each_argument do |_, arg|
                            if arg.required
                                table.argument arg.name
                            else
                                table.argument arg.name, :default => arg.default
                            end
                            arguments[arg.name] = arg.name
                        end

                        use_data_monitoring_table table, arguments
                        @embedded_table = table
                    end
                    @embedded_table
                end

                # Attach a data monitoring table on this fault response table
                #
                # @param [Model<DataMonitoringTable>] table a data monitoring table
                #   model
                # @param [{String=>String,#name}] arguments from the name of an
                #   argument on the data monitoring table to the corresponding
                #   argument on the fault response table. All arguments required
                #   by the data monitoring table should be set this way
                def use_data_monitoring_table(table, arguments = Hash.new)
                    table.each_argument do |_, arg|
                        if arg.required && !arguments[arg.name]
                            raise ArgumentError, "#{table} requires an argument called #{arg.name}"
                        end
                    end
                    data_monitoring_tables << UsedDataMonitoringTable.new(table, arguments)
                    self
                end

                # Find a data monitor by its name
                #
                # It searches for all used data monitoring tables and returns
                # the first monitor that has the given name
                #
                # @param [String] name the monitor name
                # @return [Model<Coordination::DataMonitor>,nil] the data
                #   monitor, or nil if there is none with that name
                def find_monitor(name)
                    each_data_monitoring_table do |tbl|
                        if m = tbl.table.find_monitor(name)
                            return m
                        end
                    end
                    nil
                end

                def method_missing(m, *args, &block)
                    if monitor = MetaRuby::DSLs.find_through_method_missing(self, m, args, "monitor")
                        return monitor
                    elsif arg = arguments[m]
                        return Roby::Coordination::Models::Variable.new(m)
                    else
                        super
                    end
                end
            end
        end
    end
end

Roby::Coordination::FaultResponseTable.extend Syskit::Coordination::Models::FaultResponseTableExtension
