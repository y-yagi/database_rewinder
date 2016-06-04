require 'spec_helper'

describe DatabaseRewinder do
  before do
    DatabaseRewinder.init
  end

  describe '.[]' do
    context 'for connecting to an arbitrary database' do
      after do
        DatabaseRewinder.database_configuration = nil
      end
      subject { DatabaseRewinder.instance_variable_get(:'@cleaners').map {|c| c.connection_name} }

      context 'simply giving a connection name only' do
        before do
          DatabaseRewinder.database_configuration = {'aaa' => {'adapter' => 'sqlite3', 'database' => ':memory:'}}
          DatabaseRewinder['aaa']
        end
        it { should eq ['aaa'] }
      end

      context 'giving a connection name via Hash with :connection key' do
        before do
          DatabaseRewinder.database_configuration = {'bbb' => {'adapter' => 'sqlite3', 'database' => ':memory:'}}
          DatabaseRewinder[connection: 'bbb']
        end
        it { should eq ['bbb'] }
      end

      context 'the Cleaner compatible syntax' do
        before do
          DatabaseRewinder.database_configuration = {'ccc' => {'adapter' => 'sqlite3', 'database' => ':memory:'}}
          DatabaseRewinder[:aho, connection: 'ccc']
        end
        it { should eq ['ccc'] }
      end
    end

    context 'for connecting to multiple databases' do
      before do
        DatabaseRewinder[:active_record, connection: 'test']
        DatabaseRewinder[:active_record, connection: 'test2']

        Foo.create! name: 'foo1'
        Quu.create! name: 'quu1'

        DatabaseRewinder.clean
      end
      it 'should clean all configured databases' do
        Foo.count.should eq 0
        Quu.count.should eq 0
      end
    end
  end

  describe '.record_inserted_table' do
    before do
      DatabaseRewinder.database_configuration = {'foo' => {'adapter' => 'sqlite3', 'database' => 'db/test_record_inserted_table.sqlite3'}}
      @cleaner = DatabaseRewinder.create_cleaner 'foo'
      connection = ::ActiveRecord::Base.sqlite3_connection(adapter: "sqlite3", database: File.expand_path('db/test_record_inserted_table.sqlite3', Rails.root))
      DatabaseRewinder.record_inserted_table(connection, sql)
    end
    after do
      DatabaseRewinder.database_configuration = nil
    end
    subject { @cleaner }

    context 'common database' do
      context 'include database name' do
        let(:sql) { 'INSERT INTO "database"."foos" ("name") VALUES (?)' }
        its(:inserted_tables) { should eq ['foos'] }
      end
      context 'only table name' do
        let(:sql) { 'INSERT INTO "foos" ("name") VALUES (?)' }
        its(:inserted_tables) { should eq ['foos'] }
      end
      context 'without "INTO"' do
        let(:sql) { 'INSERT "foos" ("name") VALUES (?)' }
        its(:inserted_tables) { should eq ['foos'] }
      end
    end

    context 'Database accepts more than one dots in an object notation (e.g. SQLServer)' do
      context 'full joined' do
        let(:sql) { 'INSERT INTO server.database.schema.foos ("name") VALUES (?)' }
        its(:inserted_tables) { should eq ['foos'] }
      end
      context 'missing one' do
        let(:sql) { 'INSERT INTO database..foos ("name") VALUES (?)' }
        its(:inserted_tables) { should eq ['foos'] }
      end

      context 'missing two' do
        let(:sql) { 'INSERT INTO server...foos ("name") VALUES (?)' }
        its(:inserted_tables) { should eq ['foos'] }
      end
    end

    context 'when database accepts INSERT IGNORE INTO statement' do
      let(:sql) { "INSERT IGNORE INTO `foos` (`name`) VALUES ('alice'), ('bob') ON DUPLICATE KEY UPDATE `foos`.`updated_at`=VALUES(`updated_at`)" }
      its(:inserted_tables) { should eq ['foos'] }
    end
  end

  describe '.clean' do
    before do
      Foo.create! name: 'foo1'
      Bar.create! name: 'bar1'
      DatabaseRewinder.clean
    end
    it 'should clean' do
      Foo.count.should eq 0
      Bar.count.should eq 0
    end
  end

  if ActiveRecord::VERSION::STRING >= '4'
    describe '.clean_all should not touch AR::SchemaMigration' do
      before do
        ActiveRecord::SchemaMigration.create_table
        ActiveRecord::SchemaMigration.create! version: '001'
        Foo.create! name: 'foo1'
        DatabaseRewinder.clean_all
      end
      after { ActiveRecord::SchemaMigration.drop_table }
      it 'should clean except schema_migrations' do
        Foo.count.should eq 0
        ActiveRecord::SchemaMigration.count.should eq 1
      end
    end
  end

  describe '.clean_with' do
    before do
      @cleaner = DatabaseRewinder.cleaners.first
      @only = @cleaner.instance_variable_get(:@only)
      @except = @cleaner.instance_variable_get(:@except)
      Foo.create! name: 'foo1'
      Bar.create! name: 'bar1'
      DatabaseRewinder.clean_with :truncation, options
    end

    context 'with only option' do
      let(:options) { { only: ['foos'] } }
      it 'should clean with only option and restore original one' do
        Foo.count.should eq 0
        Bar.count.should eq 1
        expect(@cleaner.instance_variable_get(:@only)).to eq(@only)
      end
    end

    context 'with except option' do
      let(:options) { { except: ['bars'] } }
      it 'should clean with except option and restore original one' do
        Foo.count.should eq 0
        Bar.count.should eq 1
        expect(@cleaner.instance_variable_get(:@except)).to eq(@except)
      end
    end
  end

  describe '.cleaning' do
    context 'without exception' do
      before do
        DatabaseRewinder.cleaning do
          Foo.create! name: 'foo1'
        end
      end

      it 'should clean' do
        expect(Foo.count).to be_zero
      end
    end

    context 'with exception' do
      it 'should clean regardless of exception' do
        expect {
          DatabaseRewinder.cleaning do
            Foo.create! name: 'foo1'; fail
          end
        }.to raise_error
        expect(Foo.count).to be_zero
      end
    end
  end

  describe '.strategy=' do
    context 'call first with options' do
      before do
        DatabaseRewinder.strategy = :truncate, { only: ['foos'], except: ['bars'] }
      end

      it 'should set options' do
        expect(DatabaseRewinder.instance_variable_get(:@only)).to eq(['foos'])
        expect(DatabaseRewinder.instance_variable_get(:@except)).to eq(['bars'])
      end

      it 'should create cleaner with options' do
        cleaner = DatabaseRewinder.instance_variable_get(:@cleaners).first
        expect(cleaner.instance_variable_get(:@only)).to eq(['foos'])
        expect(cleaner.instance_variable_get(:@except)).to eq(['bars'])
      end

      context 'call again with different options' do
        before do
          DatabaseRewinder.strategy = :truncate, { only: ['bazs'], except: [] }
        end

        it 'should overwrite options' do
          expect(DatabaseRewinder.instance_variable_get(:@only)).to eq(['bazs'])
          expect(DatabaseRewinder.instance_variable_get(:@except)).to eq([])
        end

        it 'should overwrite cleaner with new options' do
          cleaner = DatabaseRewinder.instance_variable_get(:@cleaners).first
          expect(cleaner.instance_variable_get(:@only)).to eq(['bazs'])
          expect(cleaner.instance_variable_get(:@except)).to eq([])
        end
      end
    end
  end
end
