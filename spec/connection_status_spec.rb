require 'spec_helper'
require 'tmpdir'

RSpec.describe RLS, 'connection status' do
  let(:tenant) { Tenant.create! name: 'A' }
  let(:other_tenant) { Tenant.create! name: 'B' }

  before { RLS.reset! }

  def database_tenant_id(connection = ActiveRecord::Base.connection)
    connection.select_value("SELECT current_setting('rls.tenant_id', TRUE)").to_s
  end

  def statements
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] unless payload[:name] == 'SCHEMA' }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') { yield }
    sql
  end

  describe '.set_tenant_for_block' do
    it 'sends one statement to enter the block and one to leave it' do
      tenant
      expect(statements { RLS.set_tenant_for_block(tenant) {} }.size).to eq 2
    end
  end

  describe '.set_tenant' do
    it 'sends a single statement' do
      tenant
      expect(statements { RLS.set_tenant tenant }.size).to eq 1
    end

    # A reset leaves rls.disable as '', which policies cannot cast to a boolean.
    it 'enables RLS explicitly' do
      RLS.set_tenant tenant
      expect(RLS.status[:disable]).to eq 'false'
    end

    it 'sends nothing when the tenant is already set' do
      RLS.set_tenant tenant
      expect(statements { RLS.set_tenant tenant }).to be_empty
    end
  end

  describe '.status' do
    it 'does not query the database once the connection has a status' do
      RLS.set_tenant tenant
      expect(statements { RLS.status }).to be_empty
    end

    it 'matches the database after a block restores it' do
      RLS.set_tenant tenant
      RLS.set_tenant_for_block(other_tenant) {}
      expect(database_tenant_id).to eq tenant.id.to_s
    end
  end

  describe '.restore_status_after_block' do
    it 'sends nothing when the block changed nothing' do
      RLS.set_tenant tenant
      expect(statements { RLS.restore_status_after_block {} }).to be_empty
    end
  end

  context 'when the connection is checked out again' do
    it 'resets the database settings' do
      RLS.set_tenant tenant
      ActiveRecord::Base.connection_pool.release_connection
      expect(database_tenant_id).to eq ''
    end
  end

  context 'when the connection reconnects' do
    it 're-applies the tenant to the new session' do
      RLS.set_tenant tenant
      ActiveRecord::Base.connection.reconnect!
      expect(database_tenant_id).to eq tenant.id.to_s
    end
  end

  context 'when a transaction that set the tenant rolls back' do
    it 'sets the tenant again on the next call' do
      other_tenant
      RLS.set_tenant tenant
      ActiveRecord::Base.transaction(requires_new: true) do
        RLS.set_tenant other_tenant
        raise ActiveRecord::Rollback
      end
      RLS.set_tenant other_tenant
      expect(database_tenant_id).to eq other_tenant.id.to_s
    end
  end

  context 'with two threads' do
    it 'keeps each thread on its own tenant' do
      ids = [tenant, other_tenant].map do |t|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            RLS.set_tenant t
            sleep 0.01
            [t.id.to_s, database_tenant_id(connection), RLS.current_tenant_id]
          end
        end
      end.map(&:value)

      expect(ids).to all(satisfy { |expected, database, cached| database == expected && cached == expected })
    end
  end

  context 'with an unprivileged role' do
    around do |example|
      connection = ActiveRecord::Base.connection
      connection.execute <<~SQL
        DO $$ BEGIN CREATE ROLE rls_spec_unprivileged NOLOGIN; EXCEPTION WHEN duplicate_object THEN NULL; END $$;
        GRANT rls_spec_unprivileged TO CURRENT_USER;
      SQL
      RLS::Railtie.config.rls_rails.unprivileged_db_role = 'rls_spec_unprivileged'
      example.run
    ensure
      RLS::Railtie.config.rls_rails.unprivileged_db_role = nil
      ActiveRecord::Base.connection_pool.disconnect!
    end

    # The unprivileged role has no grants in the dummy app, so fixtures are created first.
    before { RLS.disable_for_block { tenant && other_tenant } }

    def database_role
      ActiveRecord::Base.connection.select_value('SELECT current_user')
    end

    it 're-applies the restored tenant when the connection reconnects after a rollback' do
      other_tenant
      RLS.set_tenant tenant
      ActiveRecord::Base.transaction(requires_new: true) do
        RLS.set_tenant other_tenant
        raise ActiveRecord::Rollback
      end
      ActiveRecord::Base.connection.reconnect!
      expect([database_role, database_tenant_id]).to eq ['rls_spec_unprivileged', tenant.id.to_s]
    end

    it 'returns a checked-out connection to the unprivileged role' do
      RLS.set_tenant tenant
      RLS.disable!
      ActiveRecord::Base.connection_pool.release_connection
      expect(database_role).to eq 'rls_spec_unprivileged'
    end

    it 'puts a new connection on the unprivileged role' do
      ActiveRecord::Base.connection_pool.disconnect!
      expect(database_role).to eq 'rls_spec_unprivileged'
    end

    it 'sends nothing on checkout when the connection is already reset' do
      RLS.reset!
      ActiveRecord::Base.connection_pool.release_connection
      expect(statements { ActiveRecord::Base.connection.verify! }).to be_empty
    end

    it 're-applies the status from before the transaction when the connection drops during rollback' do
      other_tenant
      RLS.set_tenant tenant
      connection = ActiveRecord::Base.connection
      connection.transaction do
        RLS.set_tenant other_tenant
        allow(connection).to receive(:exec_rollback_db_transaction).and_raise(ActiveRecord::ConnectionFailed)
        raise ActiveRecord::Rollback
      end
      connection.reconnect!
      expect([database_role, database_tenant_id]).to eq ['rls_spec_unprivileged', tenant.id.to_s]
    end

    it 'restores the status from before a rolled-back savepoint' do
      other_tenant
      RLS.set_tenant tenant
      status_before = RLS.status
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.select_value('SELECT 1') # an empty outer transaction would restart instead of using a savepoint
        ActiveRecord::Base.transaction(requires_new: true) do
          RLS.disable!
          raise ActiveRecord::Rollback
        end
        expect([RLS.status, database_role]).to eq [status_before, 'rls_spec_unprivileged']
      end
    end

    it 'restores the status when a nested transaction restarts the outer one' do
      RLS.set_tenant tenant
      status_before = RLS.status
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.transaction(requires_new: true) do
          RLS.disable!
          raise ActiveRecord::Rollback
        end
        expect([RLS.status, database_role]).to eq [status_before, 'rls_spec_unprivileged']
      end
    end

    context 'when connections start privileged' do
      around do |example|
        RLS::Railtie.config.rls_rails.connections_start_privileged = true
        example.run
      ensure
        RLS::Railtie.config.rls_rails.connections_start_privileged = false
      end

      it 'keeps a new connection on the owner role after a disabled block' do
        ActiveRecord::Base.connection_pool.disconnect!
        RLS.disable_for_block {}
        expect(ActiveRecord::Base.connection.select_value('SELECT current_user = session_user')).to be true
      end

      it 'runs migrations as the role that owns the tables' do
        ActiveRecord::Base.connection_pool.release_connection
        Dir.mktmpdir do |dir|
          File.write File.join(dir, '20200101000000_rls_spec_owner_probe.rb'), <<~RUBY
            class RlsSpecOwnerProbe < ActiveRecord::Migration[#{ActiveRecord::Migration.current_version}]
              def up
                execute 'ALTER TABLE tenants ALTER COLUMN name SET STATISTICS -1'
              end
            end
          RUBY
          context = ActiveRecord::MigrationContext.new(dir)
          expect { context.migrate }.not_to raise_error
        ensure
          ActiveRecord::Base.connection.execute "DELETE FROM schema_migrations WHERE version = '20200101000000'"
        end
      end
    end
  end
end
