require "rails"

module RLS
  # A new or reconnected session starts with no settings, on the login role. Re-apply
  # what the connection had, or the default when it had nothing, so it stays scoped.
  module ReapplyStatusOnConnect
    def configure_connection
      super
      status = @rls_status
      @rls_status = { tenant_id: '', user_id: '', disable: '', privileged: true }
      @rls_transaction_status = nil
      @rls_savepoint_statuses = {}
      RLS.apply(status&.slice(*RLS::STATUS_KEYS) || RLS.connection_default_status, self)
    end
  end

  # Postgres undoes a SET made inside a transaction or savepoint that rolls back, back
  # to its value when the transaction or savepoint began. Snapshot the status there and
  # restore it on rollback, without querying: the connection may already be gone, and
  # a later reconnect re-applies the snapshot.
  module RestoreStatusOnRollback
    def begin_db_transaction(...)
      @rls_transaction_status = @rls_status&.dup
      super
    end

    def begin_isolated_db_transaction(...)
      @rls_transaction_status = @rls_status&.dup
      super
    end

    def commit_db_transaction(...)
      super
      @rls_transaction_status = nil
      @rls_savepoint_statuses&.clear
    end

    def rollback_db_transaction(...)
      super
    ensure
      @rls_status = @rls_transaction_status
      @rls_transaction_status = nil
      @rls_savepoint_statuses&.clear
    end

    def restart_db_transaction(...)
      super
      @rls_status = @rls_transaction_status&.dup
      @rls_savepoint_statuses&.clear
    end

    def create_savepoint(name = current_savepoint_name)
      (@rls_savepoint_statuses ||= {})[name] = @rls_status&.dup
      super
    end

    # Also how Active Record restarts a savepoint, so the snapshot stays until release.
    def rollback_to_savepoint(name = current_savepoint_name)
      super
      @rls_status = @rls_savepoint_statuses[name]&.dup if @rls_savepoint_statuses&.key?(name)
    end

    def release_savepoint(name = current_savepoint_name)
      super
      @rls_savepoint_statuses&.delete(name)
    end
  end

  def self.configure
    @configuration ||= Railtie.config.rls_rails
    yield @configuration if block_given?
  end

  class Railtie < ::Rails::Railtie
    config.rls_rails = ActiveSupport::OrderedOptions.new
    config.rls_rails.policy_dir = 'db/policies'
    config.rls_rails.tenant_class = nil
    config.rls_rails.user_class = nil
    config.rls_rails.tenant_fk = :tenant_id
    config.rls_rails.verbose = false
    config.rls_rails.unprivileged_db_role = nil
    config.rls_rails.connections_start_privileged = false

    initializer "rls_rails.load" do
      ActiveSupport.on_load :active_record do
        ActiveRecord::Migration.include RLS::Statements
        #ActiveRecord::Migration::CommandRecorder.include Scenic::CommandRecorder
        #ActiveRecord::SchemaDumper.prepend Scenic::SchemaDumper
      end

      ActiveSupport.on_load :active_record_postgresqladapter do
        prepend RLS::ReapplyStatusOnConnect
        prepend RLS::RestoreStatusOnRollback

        # A connection handed to another thread must not keep the previous thread's
        # settings or role. A connection not yet connected gets them on connect.
        set_callback :checkout, :after do
          RLS.apply(RLS.connection_default_status, self) if @rls_status
        end
      end
    end

    rake_tasks do
      # Rake runs migrations, schema loads and policy tasks, which need the role that
      # owns the tables. Servers and workers never load tasks, so they start closed.
      config.rls_rails.connections_start_privileged = true

      load 'rls_rails/tasks/init.rake'
      load 'rls_rails/tasks/recreate.rake'
    end
  end
end
