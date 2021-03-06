require '<%= Roby::App.resolve_robot_in_path("models/#{subdir}/#{basename}") %>'
<% indent, open, close = ::Roby::App::GenBase.in_module(*class_name[0..-2]) %>
<%= open %>
<%= indent %>describe <%= class_name.last %> do
<%= indent %>    # # What one usually wants to test for a Device would be the
<%= indent %>    # # extensions module.
<%= indent %>    # it "allows to specify the baudrate" do
<%= indent %>    #     dev = syskit_stub_device(<%= class_name.last %>)
<%= indent %>    #     dev.baudrate(1_000_000) # 1Mbit
<%= indent %>    #     assert_equal 1_000_000, dev.baudrate
<%= indent %>    # end
<%= indent %>end
<%= close %>
