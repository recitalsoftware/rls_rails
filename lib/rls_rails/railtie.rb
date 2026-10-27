require "rails"

module RLS
  # A reconnect opens a fresh session without the gem's settings, logged in as the
  # privileged role. Re-apply what the connection had, so it stays scoped.
  module ReapplyStatusOnReconnect
    def configure_connection
      super
      status = @rls_status
      @rls_status = nil
      return if status.nil? || status.values.all?(&:empty?)

      execute "SET SESSION rls.disable = '#{status[:disable]}'; SET SESSION rls.user_id = '#{status[:user_id]}'; SET SESSION rls.tenant_id = '#{status[:tenant_id]}';"
      role = RLS.unprivileged_db_role
      execute(status[:disable] == 'true' ? 'SET ROLE NONE;' : "SET ROLE #{role};") if role.present?
      @rls_status = status
    end
  end

  # Postgres undoes a SET made inside a transaction or savepoint that rolls back.
  # Read back what it restored, so a later reconnect re-applies the right status.
  # The cache is emptied first: if the rollback itself fails, a reconnect then
  # starts unscoped rather than re-applying a tenant set inside the transaction.
  module ReloadStatusOnRollback
    def rollback_db_transaction(...)
      @rls_status = nil
      super
      reload_rls_status
    end

    def rollback_to_savepoint(...)
      @rls_status = nil
      super
      reload_rls_status
    end

    def restart_db_transaction(...)
      @rls_status = nil
      super
      reload_rls_status
    end

    private

    def reload_rls_status
      values = select_rows(<<~SQL).first.map(&:to_s)
        SELECT current_setting('rls.tenant_id', TRUE), current_setting('rls.user_id', TRUE), current_setting('rls.disable', TRUE)
      SQL
      @rls_status = %i[tenant_id user_id disable].zip(values).to_h
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

    initializer "rls_rails.load" do
      ActiveSupport.on_load :active_record do
        ActiveRecord::Migration.include RLS::Statements
        #ActiveRecord::Migration::CommandRecorder.include Scenic::CommandRecorder
        #ActiveRecord::SchemaDumper.prepend Scenic::SchemaDumper

        adapter = ActiveRecord::Base.connection.class
        adapter.prepend RLS::ReapplyStatusOnReconnect
        adapter.prepend RLS::ReloadStatusOnRollback

        # A connection handed to another thread must not keep the previous thread's
        # settings or role. It goes back to how a fresh connection starts.
        adapter.set_callback :checkout, :after do
          execute "RESET rls.user_id; RESET rls.tenant_id; RESET rls.disable; RESET ROLE;"
          @rls_status = { tenant_id: '', user_id: '', disable: '' }
        end
      end
    end

    rake_tasks do
      load 'rls_rails/tasks/init.rake'
      load 'rls_rails/tasks/recreate.rake'
    end
  end
end
