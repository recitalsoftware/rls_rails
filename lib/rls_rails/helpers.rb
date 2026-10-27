require 'concurrent'

module RLS
  STATUS_KEYS = %i[tenant_id user_id disable].freeze

  def self.disable!
    return unless apply status.merge(disable: 'true')

    debug_print "WARNING: ROW LEVEL SECURITY DISABLED!\n"
  end

  def self.disabled?
    status[:disable] == 'true'
  end

  def self.enable!
    return if enabled?

    apply status.merge(disable: 'false')
    debug_print "ROW LEVEL SECURITY ENABLED!\n"
  end

  def self.enabled?
    !self.disabled?
  end

  def self.set_tenant tenant
    raise "Tenant is nil!" unless tenant.present?

    target = status.merge(tenant_id: tenant.id.to_s, disable: 'false')
    return unless apply target

    debug_print "Accessing database as #{tenant.try(:name) || "tenant id #{tenant.id}"}\n"
  end

  def self.set_user user
    raise "User is nil!" unless user.present?

    target = status.merge(user_id: user.id.to_s, disable: 'false')
    return unless apply target

    debug_print "Accessing database as #{user.class}##{user.id}\n"
  end

  def self.current_tenant_id
    status[:tenant_id].presence
  end

  def self.current_user_id
    status[:user_id].presence
  end

  # Resets all session variables set by this gem
  def self.reset!
    return unless apply(tenant_id: '', user_id: '', disable: '')

    debug_print "Resetting RLS settings.\n"
  end

  # Sets the RLS status to the given value in one go.
  # @param status [Hash]
  # @see #status
  def self.status= status
    apply(
      tenant_id: status[:tenant_id].to_s,
      user_id: status[:user_id].to_s,
      disable: status[:disable].nil? ? 'false' : status[:disable].to_s,
    )
  end

  # @return [Hash] Values of the current RLS sesssion
  # @see #status
  def self.status
    cached_status.slice(*STATUS_KEYS)
  end

  # Brings the connection to the given status, sending only the settings that differ
  # in a single statement. The role follows the status: the login role only while RLS
  # is disabled, so a connection with no tenant fails closed.
  # @return [Boolean] whether anything was sent
  def self.apply target, connection = ActiveRecord::Base.connection
    current = cached_status(connection)
    privileged = target[:disable] == 'true'
    sql = STATUS_KEYS.filter_map do |key|
      next if current[key] == target[key]

      target[key].empty? ? "RESET rls.#{key};" : "SET SESSION rls.#{key} = '#{target[key]}';"
    end
    if unprivileged_db_role.present? && current[:privileged] != privileged
      sql << (privileged ? 'SET ROLE NONE;' : "SET ROLE #{unprivileged_db_role};")
    end
    return false if sql.empty?

    connection.clear_query_cache
    connection.execute sql.join(' ')
    current.merge!(target.slice(*STATUS_KEYS), privileged: privileged)
    true
  end

  # What a connection is reset to when it is checked out of the pool.
  def self.connection_default_status
    { tenant_id: '', user_id: '', disable: connections_start_privileged? ? 'true' : '' }
  end

  # The values this gem last set on the connection, and whether it is on the login role.
  # Session variables belong to the connection, so the cache does too; the database is
  # read only when the connection has no record yet.
  def self.cached_status connection = ActiveRecord::Base.connection
    connection.instance_variable_get(:@rls_status) || connection.instance_variable_set(:@rls_status, read_status(connection))
  end

  def self.read_status connection
    result = connection.select_rows(<<-SQL).first
      SELECT current_setting('rls.tenant_id', TRUE),
             current_setting('rls.user_id',   TRUE),
             current_setting('rls.disable',   TRUE),
             current_user = session_user;
    SQL
    STATUS_KEYS.zip(result.first(3).map(&:to_s)).to_h.merge(privileged: result.last)
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

  def self.disable_for_block &block
    self.restore_status_after_block do
      self.disable!
      yield(block)
    end
  end

  # Enables RLS and sets the current tenant to the given value for the given block
  # and restores the initial configuration afterwards.
  # @param tenant
  def self.set_tenant_for_block tenant, &block
    self.restore_status_after_block do
      self.set_tenant tenant
      yield tenant, block
    end
  end

  # Ensures that the initial RLS-state is restored after the given block is run
  def self.restore_status_after_block &block
    status_was = self.status
    yield block
  ensure
    self.status = status_was
  end

  def self.run_per_tenant &block
    self.restore_status_after_block do
      tenant_class.all.map do |tenant|
        RLS.set_tenant tenant
        yield tenant, block
      end
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

  def self.connections_start_privileged?
    Railtie.config.rls_rails.connections_start_privileged
  end

  private

  def self.execute_sql query
    ActiveRecord::Base.connection.execute query
  end

  def self.debug_print s
    print s if Railtie.config.rls_rails.verbose
  end
end
