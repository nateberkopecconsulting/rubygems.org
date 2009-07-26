require File.dirname(__FILE__) + '/../test_helper'

class GemcutterTest < ActiveSupport::TestCase
  context "getting the server path" do
    should "return just the root server path with no args" do
      assert_equal "#{Rails.root}/server", Gemcutter.server_path
    end

    should "return a directory inside if one argument is given" do
      assert_equal "#{Rails.root}/server/gems", Gemcutter.server_path("gems")
    end

    should "return a directory inside if more than one argument is given" do
      assert_equal "#{Rails.root}/server/quick/Marshal.4.8", Gemcutter.server_path("quick", "Marshal.4.8")
    end
  end

  should "generate a new indexer" do
    @indexer = "indexer"
    mock(Gem::Indexer).new(Gemcutter.server_path, :build_legacy => false) { @indexer }
    assert_equal @indexer, Gemcutter.indexer
    assert @indexer.respond_to?(:say)
    assert_nil @indexer.say("Should be quiet")
  end

  context "creating a new gemcutter" do
    setup do
      @user = Factory(:email_confirmed_user)
      @gem = gem_file
      @cutter = Gemcutter.new(@user, @gem)
    end

    should "have some state" do
      assert @cutter.respond_to?(:user)
      assert @cutter.respond_to?(:data)
      assert @cutter.respond_to?(:spec)
      assert @cutter.respond_to?(:message)
      assert @cutter.respond_to?(:code)
      assert @cutter.respond_to?(:rubygem)

      assert_equal @user, @cutter.user
      assert_equal @gem, @cutter.data
    end

    context "processing incoming gems" do
      should "work normally when things go well" do
        mock(@cutter).pull_spec { true }
        mock(@cutter).find { true }
        stub(@cutter).authorize { true }
        mock(@cutter).save

        @cutter.process
      end

      should "not attempt to find rubygem if spec can't be pulled" do
        mock(@cutter).pull_spec { false }
        mock(@cutter).find.never
        mock(@cutter).authorize.never
        mock(@cutter).save.never
        @cutter.process
      end

      should "not attempt to authorize if not found" do
        mock(@cutter).pull_spec { true }
        mock(@cutter).find { nil }
        mock(@cutter).authorize.never
        mock(@cutter).save.never

        @cutter.process
      end

      should "not attempt to save if not authorized" do
        mock(@cutter).pull_spec { true }
        mock(@cutter).find { true }
        mock(@cutter).authorize { false }
        mock(@cutter).save.never

        @cutter.process
      end
    end

    context "pulling the spec " do
      should "pull spec out of the given gem" do
        data = "data"
        format = "format"
        io = "io"
        spec = "spec"

        mock(@cutter).data { data }
        mock(data).string { "test" }
        mock(StringIO).new("test") { io }
        mock(Gem::Format).from_io(io) { format }
        mock(format).spec { spec }

        @cutter.pull_spec
        assert_equal spec, @cutter.spec
      end

      should "not be able to pull spec from a bad path" do
        stub(@cutter).data.stub!.string { raise "problem!" }
        @cutter.pull_spec
        assert_nil @cutter.spec
        assert_match %r{Gemcutter cannot process this gem}, @cutter.message
        assert_equal @cutter.code, 422
      end
    end

    context "finding rubygem" do
      should "initialize new gem if one does not exist" do
        stub(@cutter).spec.stub!.name { "some name" }
        @cutter.find

        assert_not_nil @cutter.rubygem
        assert @cutter.rubygem.new_record?
      end

      should "bring up existing gem with matching spec" do
        @rubygem = Factory(:rubygem)
        stub(@cutter).spec.stub!.name { @rubygem.name }
        @cutter.find

        assert_equal @rubygem, @cutter.rubygem
      end
    end

    context "checking if the rubygem can be pushed to" do
      should "be true if rubygem is new" do
        stub(@cutter).rubygem { Rubygem.new }
        assert @cutter.authorize
      end

      context "with a existing rubygem" do
        setup do
          @rubygem = Factory(:rubygem)
          stub(@cutter).rubygem { @rubygem }
        end

        should "be true if owned by the user" do
          @rubygem.ownerships.create(:user => @user, :approved => true)
          assert @cutter.authorize
        end

        should "be false if not owned by user" do
          assert ! @cutter.authorize
          assert_equal "You do not have permission to push to this gem.", @cutter.message
          assert_equal 403, @cutter.code
        end

        should "be false if rubygem exists and is owned by unapproved user" do
          @rubygem.ownerships.create(:user => @user, :approved => false)
          assert ! @cutter.authorize
          assert_equal "You do not have permission to push to this gem.", @cutter.message
          assert_equal 403, @cutter.code
        end
      end
    end

    context "with a rubygem" do
      setup do
        @rubygem = "rubygem"
        @version = "1.0.0"
        @spec = gem_spec(:version => @version)
        @ownerships = "ownerships"

        stub(@rubygem).save
        stub(@rubygem).ownerships { @ownerships }
        stub(@cutter).rubygem { @rubygem }
        stub(@cutter).spec { @spec }
      end

      context "building the gem" do
        before_should "build the name" do
          mock(@rubygem).build_name(@spec.name)
        end

        before_should "build version with platform" do
          stub(@spec).platform { "mswin" }
          stub(@spec).rubyforge_project { "project" }
          stub(@spec).rubyforge_project { "summary" }
          mock(@rubygem).build_version(
            :authors           => @spec.authors.join(", "),
            :description       => @spec.description,
            :summary           => @spec.summary,
            :rubyforge_project => @spec.rubyforge_project,
            :created_at        => @spec.date,
            :number            => "#{@version}-mswin")
        end

        before_should "build the version" do
          mock(@rubygem).build_version(
            :authors           => @spec.authors.join(", "),
            :description       => @spec.description,
            :summary           => @spec.summary,
            :rubyforge_project => @spec.rubyforge_project,
            :created_at        => @spec.date,
            :number            => @version)
        end

        before_should "build the dependencies" do
          mock(@rubygem).build_dependencies(@spec.dependencies)
        end

        before_should "build the links" do
          mock(@rubygem).build_links(@spec.homepage)
        end

        before_should "build ownership with user" do
          mock(@rubygem).build_ownership(@user)
        end

        setup do
          stub(@rubygem).build_name
          stub(@rubygem).build_version
          stub(@rubygem).build_dependencies
          stub(@rubygem).build_links
          stub(@rubygem).build_ownership
          @cutter.build
        end
      end

      context "saving the rubygem" do
        before_should "process if succesfully saved" do
          mock(@cutter).build
          mock(@rubygem).save { true }
          mock(@cutter).store
          mock(@cutter).notify("Successfully registered gem: #{@rubygem}", 200)
        end

        before_should "not process if succesfully saved" do
          mock(@cutter).build
          mock(@rubygem).save { false }
          mock(@cutter).store.never
          mock(@cutter).notify("Gemcutter cannot process this gem. Please try rebuilding it and installing it locally to make sure it's valid.", 403)
        end

        setup do
          @cutter.save
        end
      end
    end
  end
end
