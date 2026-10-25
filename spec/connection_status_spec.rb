require 'spec_helper'

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

  describe '.set_tenant' do
    it 'sends a single statement' do
      tenant
      expect(statements { RLS.set_tenant tenant }.size).to eq 1
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
end
