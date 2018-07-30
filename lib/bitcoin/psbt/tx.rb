module Bitcoin
  module PSBT

    class Tx
      attr_accessor :tx
      attr_reader :inputs
      attr_reader :outputs
      attr_accessor :unknowns

      def initialize(tx = nil)
        @tx = tx
        @inputs = tx ? tx.in.map{Input.new}: []
        @outputs = tx ? tx.out.map{Output.new}: []
        @unknowns = {}
      end

      # parse Partially Signed Bitcoin Transaction data with Base64 format.
      # @param [String] base64 a Partially Signed Bitcoin Transaction data with Base64 format.
      # @return [Bitcoin::PartiallySignedTx]
      def self.parse_from_base64(base64)
        self.parse_from_payload(Base64.decode64(base64))
      end

      # parse Partially Signed Bitcoin Transaction data.
      # @param [String] payload a Partially Signed Bitcoin Transaction data with binary format.
      # @return [Bitcoin::PartiallySignedTx]
      def self.parse_from_payload(payload)
        buf = StringIO.new(payload)
        raise ArgumentError, 'Invalid PSBT magic bytes.' unless buf.read(4).unpack('N').first == PSBT_MAGIC_BYTES
        raise ArgumentError, 'Invalid PSBT separator.' unless buf.read(1).bth.to_i(16) == 0xff
        partial_tx = self.new

        # read global data.
        until buf.eof?
          key_len = Bitcoin.unpack_var_int_from_io(buf)
          break if key_len == 0
          key_type = buf.read(1).unpack('C').first
          key = buf.read(key_len - 1)
          value = buf.read(Bitcoin.unpack_var_int_from_io(buf))

          case key_type
          when PSBT_GLOBAL_TYPES[:unsigned_tx]
            raise ArgumentError, 'Duplicate Key, unsigned tx already provided' if partial_tx.tx
            partial_tx.tx = Bitcoin::Tx.parse_from_payload(value)
            partial_tx.tx.in.each do |tx_in|
              raise ArgumentError, 'Unsigned tx does not have empty scriptSigs and scriptWitnesses.' if !tx_in.script_sig.empty? || !tx_in.script_witness.empty?
            end
          else
            raise ArgumentError, 'Duplicate Key, key for unknown value already provided' if partial_tx.unknowns[key]
            partial_tx.unknowns[([key_type].pack('C') + key).bth] = value
          end
        end

        raise ArgumentError, 'No unsigned transcation was provided.' unless partial_tx.tx

        # read input data.
        partial_tx.tx.in.each do |tx_in|
          break if buf.eof?
          input = Input.parse_from_buf(buf)
          partial_tx.inputs << input
          if input.non_witness_utxo && input.non_witness_utxo.hash != tx_in.prev_hash
            raise ArgumentError, 'Non-witness UTXO does not match outpoint hash'
          end
        end

        raise ArgumentError, 'Inputs provided does not match the number of inputs in transaction.' unless partial_tx.inputs.size == partial_tx.tx.in.size

        # read output data.
        partial_tx.tx.outputs.each do
          break if buf.eof?
          output = Output.parse_from_buf(buf)
          break unless output
          partial_tx.outputs << output
        end

        raise ArgumentError, 'Outputs provided does not match the number of outputs in transaction.' unless partial_tx.outputs.size == partial_tx.tx.out.size

        partial_tx.inputs.each do |input|
          raise ArgumentError, 'PSBT is not sane.' unless input.sane?
        end

        partial_tx
      end

      # generate payload.
      # @return [String] a payload with binary format.
      def to_payload
        payload = PSBT_MAGIC_BYTES.to_even_length_hex.htb << 0xff.to_even_length_hex.htb

        payload << PSBT.serialize_to_vector(PSBT_GLOBAL_TYPES[:unsigned_tx], value: tx.to_payload)

        payload << unknowns.map {|k,v|Bitcoin.pack_var_int(k.htb.bytesize) << k.htb << Bitcoin.pack_var_int(v.bytesize) << v}.join

        payload << PSBT_SEPARATOR.to_even_length_hex.htb

        payload << inputs.map(&:to_payload).join
        payload << outputs.map(&:to_payload).join
        payload
      end

      # generate payload with Base64 format.
      # @return [String] a payload with Base64 format.
      def to_base64
        Base64.strict_encode64(to_payload)
      end

      # update input key-value maps.
      # @param [Bitcoin::Tx] prev_tx previous tx reference by input.
      # @param [Bitcoin::Script] redeem_script redeem script to set input.
      # @param [Bitcoin::Script] witness_script witness script to set input.
      # @param [Hash] hd_key_paths bip 32 hd key paths to set input.
      def update!(prev_tx, redeem_script: nil, witness_script: nil, hd_key_paths: [])
        prev_hash = prev_tx.hash
        tx.in.each_with_index do|tx_in, i|
          if tx_in.prev_hash == prev_hash
            utxo = prev_tx.out[tx_in.out_point.index]
            raise ArgumentError, 'redeem script does not match utxo.' if redeem_script && !utxo.script_pubkey.include?(redeem_script.to_hash160)
            raise ArgumentError, 'witness script does not match redeem script.' if redeem_script && witness_script && !redeem_script.include?(witness_script.to_sha256)
            if utxo.script_pubkey.witness_program? || (redeem_script && redeem_script.witness_program?)
              inputs[i].witness_utxo = utxo
            else
              inputs[i].non_witness_utxo = prev_tx
            end
            inputs[i].redeem_script = redeem_script if redeem_script
            inputs[i].witness_script = witness_script if witness_script
            inputs[i].hd_key_paths = hd_key_paths.map(&:pubkey).zip(hd_key_paths).to_h
          end
        end
      end

      # get signature script of input specified by +index+
      # @param [Integer] index input index.
      # @return [Bitcoin::Script]
      def signature_script(index)
        i = inputs[index]
        if i.non_witness_utxo
          i.redeem_script ? i.redeem_script : i.non_witness_utxo.out[tx.in[index].out_point.index].script_pubkey
        else
          i.witness_script ? i.witness_script : i.witness_utxo
        end
      end

      # merge two PSBTs to create one PSBT.
      # TODO This feature is experimental.
      # @param [Bitcoin::PartiallySignedTx] psbt PSBT to be combined which must have same property in PartiallySignedTx.
      # @return [Bitcoin::PartiallySignedTx] combined object.
      def merge(psbt)
        raise ArgumentError, 'The argument psbt must be an instance of Bitcoin::PSBT::Tx.' unless psbt.is_a?(Bitcoin::PSBT::Tx)
        raise ArgumentError, 'The combined transactions are different.' unless tx == psbt.tx
        raise ArgumentError, 'The Partially Signed Input\'s count are different.' unless inputs.size == psbt.inputs.size
        raise ArgumentError, 'The Partially Signed Output\'s count are different.' unless outputs.size == psbt.outputs.size

        combined = Bitcoin::PSBT::Tx.new(tx)
        inputs.each_with_index do |i, index|
          combined.inputs[index] = i.merge(psbt.inputs[index])
        end
        outputs.each_with_index do |o, index|
          combined.outputs[index] = o.merge(psbt.outputs[index])
        end
        combined.unknowns = unknowns.merge(psbt.unknowns)
        combined
      end

      # finalize tx.
      # TODO This feature is experimental and support only multisig.
      # @return [Bitcoin::PSBT::Tx] finalized PSBT.
      def finalize!
        inputs.each {|input|input.finalize!}
        self
      end

      # extract final tx.
      # @return [Bitcoin::Tx] final tx.
      def extract_tx
        extract_tx = tx.dup
        inputs.each_with_index do |input, index|
          extract_tx.in[index].script_sig = input.final_script_sig if input.final_script_sig
          extract_tx.in[index].script_witness = input.final_script_witness if input.final_script_witness
        end
        # validate signature
        tx.in.each_with_index do |tx_in, index|
          input = inputs[index]
          if input.non_witness_utxo
            utxo = input.non_witness_utxo.out[tx_in.out_point.index]
            raise "input[#{index}]'s signature is invalid.'" unless tx.verify_input_sig(index, utxo.script_pubkey)
          else
            utxo = input.witness_utxo
            raise "input[#{index}]'s signature is invalid.'" unless tx.verify_input_sig(index, utxo.script_pubkey, amount: input.witness_utxo.value)
          end
        end
        extract_tx
      end

    end

  end
end