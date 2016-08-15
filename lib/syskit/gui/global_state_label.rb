module Syskit
    module GUI
        # Representation of the state of the connected Roby instance
        class GlobalStateLabel < StateLabel
            # Actions that are shown when the context menu is activated
            #
            # @return [Array<Qt::Action>] the list of actions that can be
            #   performed on the remote Roby instance (e.g. start/stop ...)
            attr_reader :actions

            # @param [Array<Qt::Action>] actions the list of Qt actions that
            #   should be added to the context menu
            def initialize(actions: Array.new, **options)
                super(extra_style: 'margin-left: 2px; margin-top: 2px; font-size: 10pt;',
                      **options)
                @actions = actions
                declare_state 'LIVE', :green
                declare_state 'REPLAY', :green
                declare_state 'UNREACHABLE', :red
            end

            # @api private
            #
            # Qt handler called when the context menu is activated
            def contextMenuEvent(event)
                if !actions.empty?
                    menu = Qt::Menu.new(self)
                    actions.each { |act| menu.add_action(act) }
                    menu.exec(event.global_pos)
                    event.accept
                end
            end

            # @api private
            #
            # Qt handler called when the mouse is pressed
            def mousePressEvent(event)
                event.accept
            end

            # @api private
            #
            # Qt handler called when the mouse is released
            #
            # It emits the 'clicked' signal
            def mouseReleaseEvent(event)
                emit clicked
                event.accept
            end
            signals :clicked
        end
    end
end

