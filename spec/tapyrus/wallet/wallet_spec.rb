require 'spec_helper'

describe Tapyrus::Wallet do

  describe '#default_path_prefix' do
    context 'dev', network: :dev do
      subject { Tapyrus::Wallet::Base.default_path_prefix }

      it { is_expected.to eq "#{Dir.home}/.tapyrusrb/dev/db/wallet/" }
    end

    context 'change network from regtest to testnet', network: :prod do
      it 'should return path with network prefix' do
        expect(Tapyrus::Wallet::Base.default_path_prefix).to eq "#{Dir.home}/.tapyrusrb/prod/db/wallet/"
        Tapyrus.chain_params = :dev
        expect(Tapyrus::Wallet::Base.default_path_prefix).to eq "#{Dir.home}/.tapyrusrb/dev/db/wallet/"
      end
    end

  end

  describe '#load' do
    context 'existing wallet' do
      subject { Tapyrus::Wallet::Base.load(1, TEST_WALLET_PATH)}

      before do
        wallet = create_test_wallet
        wallet.close
      end
      after { subject.close }

      it 'should return wallet' do
        expect(subject.wallet_id).to eq(1)
        expect(subject.path).to eq(test_wallet_path(1))
        expect(subject.version).to eq(Tapyrus::Wallet::Base::VERSION)
      end
    end

    context 'dose not exist wallet' do
      it 'should raise error' do
        expect{Tapyrus::Wallet::Base.load(2, TEST_WALLET_PATH)}.to raise_error(ArgumentError)
      end
    end
  end

  describe '#create' do
    context 'should create new wallet' do
      subject {Tapyrus::Wallet::Base.create(2, TEST_WALLET_PATH)}
      it 'should be create' do
        expect(subject.wallet_id).to eq(2)
        expect(subject.master_key.mnemonic.size).to eq(24)
        expect(subject.version).to eq(Tapyrus::Wallet::Base::VERSION)
      end
      after{
        subject.close
        FileUtils.rm_r(test_wallet_path(2))
      }
    end

    context 'same wallet_id already exist' do
      it 'should raise error' do
        expect{Tapyrus::Wallet::Base.create(1, TEST_WALLET_PATH)}.to raise_error(ArgumentError)
      end
    end
  end

  describe '#wallets_path' do
    subject { Tapyrus::Wallet::Base.wallet_paths(TEST_WALLET_PATH) }
    it 'should return wallet dir.' do
      expect(subject[0]).to eq("#{TEST_WALLET_PATH}wallet1/")
    end
  end

  describe '#create_account', network: :prod do
    subject {
      allow(Tapyrus::Wallet::MasterKey).to receive(:generate).and_return(test_master_key)
      wallet = create_test_wallet(3)
      wallet.create_account('hoge')
      wallet
    }
    it 'should be created' do
      accounts = subject.accounts
      expect(accounts.size).to eq(2)
      expect(accounts[0].purpose).to eq(84)
      expect(accounts[0].index).to eq(0)
      expect(accounts[0].name).to eq('Default')
      expect(accounts[0].receive_depth).to eq(0)
      receive_keys = accounts[0].derived_receive_keys
      expect(receive_keys[0].addr).to eq('1JaUQDVNRdhfNsVncGkXedaPSM5Gc54Hso')
      expect(receive_keys.size).to eq(1)
      expect(receive_keys[0].hardened?).to be false
      expect(accounts[0].change_depth).to eq(0)
      change_keys = accounts[0].derived_change_keys
      expect(change_keys[0].addr).to eq('16fuuGhkywq9pB7BBxi3btQ3C3s4f4dz1N')
      expect(change_keys.size).to eq(1)
      expect(change_keys[0].hardened?).to be false
      expect(accounts[0].lookahead).to eq(10)
      expect(accounts[1].name).to eq('hoge')
      expect(accounts[1].index).to eq(1)

      # Account with same name can not be registered
      expect{subject.create_account('hoge')}.to raise_error(ArgumentError)
    end
  end

  describe '#accounts' do
    subject {
      wallet = create_test_wallet(4)
      wallet.create_account('native segwit1')
      wallet.create_account(Tapyrus::Wallet::Account::PURPOSE_TYPE[:legacy], 'legacy')
      wallet.create_account('native segwit2')
      wallet
    }
    it 'should return target accounts' do
      expect(subject.accounts.size).to eq(4)
      expect(subject.accounts(Tapyrus::Wallet::Account::PURPOSE_TYPE[:legacy]).size).to eq(1)
      expect(subject.accounts(Tapyrus::Wallet::Account::PURPOSE_TYPE[:native_segwit]).size).to eq(3)
    end
  end

  describe '#generate_new_address' do
    subject {
      allow(Tapyrus::Wallet::MasterKey).to receive(:generate).and_return(test_master_key)
      create_test_wallet(5)
    }
    it 'should return new address' do
      expect(subject.generate_new_address('Default')).to eq('mqhB5Q36hdgWv2hLhyDk79zzi7MxjRYfHn')
      expect(subject.generate_new_address('Default')).to eq('mkC8Nz9nnBc8RpgeKDMZLHavrHsTG3EhMA')
      # account name does not exist.
      expect{subject.generate_new_address('hoge')}.to raise_error(ArgumentError)
    end
  end

  describe '#watch_targets' do
    subject {
      # TODO add utxo outpoints data
      allow(Tapyrus::Wallet::MasterKey).to receive(:generate).and_return(test_master_key)
      wallet = create_test_wallet(6)
      account1 = wallet.create_account('native segwit1')
      account1.create_receive
      account1.create_receive
      account1.create_change
      wallet.watch_targets
    }
    it 'should return pubkey hash in the wallet.' do
      expect(subject.size).to eq(7)
      expect(subject[0]).to eq('d0c4a3ef09e997b6e99e397e518fe3e41a118ca1') # m/84'/1'/0'/0/0 default
      expect(subject[1]).to eq('2f34aa1cf00a53b055a291a03a7d45f0a6988b52') # m/84'/1'/0'/1/0 default
      expect(subject[2]).to eq('0fa17461c68ec2241a4c4a5edf799cbe2f8fb449') # m/84'/1'/1'/0/0 account1
      expect(subject[3]).to eq('24d6a2ce123c8be57fb5ff2394f2aadd3905419b') # m/84'/1'/1'/0/1 account1
    end
  end

  describe '#current_wallet' do
    subject {
      if Tapyrus::Wallet::Base.wallet_paths(TEST_WALLET_PATH).empty?
        wallet = create_test_wallet
        wallet.close
      end
      Tapyrus::Wallet::Base.current_wallet(TEST_WALLET_PATH)
    }
    it 'should return wallet' do
      expect(subject.path).to start_with TEST_WALLET_PATH
    end
  end

end
