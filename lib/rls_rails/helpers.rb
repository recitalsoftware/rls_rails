require 'concurrent'

module RLS
  # This variable is very problematic and not relieable, since in a
  # threaded environment of a connection pool this module is changed and
  # race conditions can occur, de-syncing the module-status with the true db status.
  def self.disable!
    return if RLS.status[:disable] === 'true' # do not use disabled? here since it may be blank

    enable_query_cache
    execute_sql('SET SESSION rls.disable = TRUE;')
    set_role(privileged: true)
    thread_rls_status.merge!(disabled: 'true')
    debug_print "WARNING: ROW LEVEL SECURITY DISABLED!\n"
  end

  def self.disabled?
    execute_sql(<<-SQL.strip_heredoc).values[0][0] === true
      SELECT NULLIF(current_setting('rls.disable', TRUE), '')::BOOLEAN;
    SQL
  end

  def self.enable!
    return if enabled?

    disable_query_cache
    debug_print "ROW LEVEL SECURITY ENABLED!\n"
    execute_sql('SET SESSION rls.disable = FALSE;')
    set_role(privileged: false)
    thread_rls_status.merge!(disabled: 'false')
  end

  def self.enabled?
    !disabled?
  end

  def self.set_tenant(tenant)
    raise 'Tenant is nil!' unless tenant.present?
    return if status[:tenant_id] === tenant.id&.to_s && enabled?

    disable_query_cache
    debug_print "Accessing database as #{tenant.try(:name) || "tenant id #{tenant.id}"}\n"
    execute_sql "SET SESSION rls.disable = FALSE; SET SESSION rls.tenant_id = #{tenant.id};"
    set_role(privileged: false)
    execute_sql("SET ROLE #{unprivileged_db_role}") if unprivileged_db_role.present?
    thread_rls_status.merge!(tenant_id: tenant.id.to_s)
  end

  def self.set_user(user)
    raise 'User is nil!' unless user.present?
    return if status[:user_id] === user.id&.to_s && enabled?

    disable_query_cache
    debug_print "Accessing database as #{user.class}##{user.id}\n"
    execute_sql "SET SESSION rls.disable = FALSE; SET SESSION rls.user_id = #{user.id};"
    set_role(privileged: false)
    thread_rls_status.merge!(user_id: user.id.to_s)
  end

  def self.current_tenant_id
    execute_sql(<<-SQL.strip_heredoc).values[0][0].presence
      SELECT current_setting('rls.tenant_id', TRUE);
    SQL
  end

  # Resets all session variables set by this gem
  def self.reset!
    return if status[:tenant_id] === '' && status[:user_id] === '' && status[:disabled] === ''

    debug_print "Resetting RLS settings.\n"
    execute_sql <<-SQL
      RESET rls.user_id;
      RESET rls.tenant_id;
      RESET rls.disable;
    SQL
    set_role(privileged: false)
    enable_query_cache
    thread_rls_status.merge!(tenant_id: '', user_id: '', disabled: '')
  end

  # Sets the RLS status to the given value in one go.
  # @param status [Hash]
  # @see #status
  def self.status=(status)
    tenant_id = status[:tenant_id].to_s
    user_id = status[:user_id].to_s
    disable = status[:disable].nil? ? 'false' : status[:disable].to_s
    if self.status[:tenant_id] === tenant_id && self.status[:user_id] === user_id && self.status[:disabled] === disable
      return
    end

    if status[:disable] && status[:disable] != 'false'
      enable_query_cache
    else
      disable_query_cache
    end

    execute_sql <<-SQL.strip_heredoc
      SET SESSION rls.disable = '#{disable}'; SET SESSION rls.user_id = '#{user_id}'; SET SESSION rls.tenant_id = '#{tenant_id}';
    SQL
    set_role(privileged: status[:disable] && status[:disable] != 'false')
    thread_rls_status.merge!(tenant_id: tenant_id, user_id: user_id, disabled: disable)
  end

  # @return [Hash] Values of the current RLS sesssion
  # @see #status
  def self.status
    result = execute_sql(<<-SQL).values[0]
      SELECT current_setting('rls.tenant_id', TRUE), current_setting('rls.user_id', TRUE), current_setting('rls.disable', TRUE);
    SQL
    %i[tenant_id user_id disable].zip(result).to_h
  end

  def self.current_tenant
    id = current_tenant_id
    return nil unless id

    tenant_class.find id
  end

  def self.current_user
    id = current_user_id
    return nil unless id

    user_class.find id
  end

  def self.disable_for_block(&block)
    restore_status_after_block do
      disable!
      yield(block)
    end
  end

  # Enables RLS and sets the current tenant to the given value for the given block
  # and restores the initial configuration afterwards.
  # @param tenant
  def self.set_tenant_for_block(tenant, &block)
    restore_status_after_block do
      enable!
      set_tenant tenant
      yield tenant, block
    end
  end

  # Ensures that the initial RLS-state is restored after the given block is run
  def self.restore_status_after_block(&block)
    status_was = status
    begin
      yield block
    ensure
      self.status = status_was
    end
  end

  def self.run_per_tenant(&block)
    restore_status_after_block do
      tenant_class.all.map do |tenant|
        RLS.set_tenant tenant
        yield tenant, block
      end
    end
  end

  def self.set_role(privileged: false)
    return unless unprivileged_db_role.present?

    if privileged
      execute_sql('SET ROLE NONE;')
    else
      execute_sql("SET ROLE #{unprivileged_db_role};")
    end
  end

  def self.tenant_class
    Railtie.config.rls_rails.tenant_class
  end

  def self.user_class
    Railtie.config.rls_rails.user_class
  end

  def self.unprivileged_db_role
    Railtie.config.rls_rails.unprivileged_db_role
  end

  def self.clear_query_cache
    ActiveRecord::Base.connection.clear_query_cache
  end

  def self.disable_query_cache
    ActiveRecord::Base.connection.disable_query_cache!
  end

  def self.enable_query_cache
    ActiveRecord::Base.connection.enable_query_cache!
  end

  def self.execute_sql(query)
    ActiveRecord::Base.connection.execute query
  end

  def self.debug_print(s)
    print s if Railtie.config.rls_rails.verbose
  end

  def self.thread_rls_status
    Thread.current['rls_status'] ||= { user_id: '', tenant_id: '', disabled: '' }
  end
end
