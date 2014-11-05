require 'jsonpath'
require 'json'

module Looksist
  module Hashed
    extend ActiveSupport::Concern
    include Looksist::Common

    module ClassMethods
      def inject(opts)
        raise 'Incorrect usage' unless [:after, :using, :populate].all? { |e| opts.keys.include? e }

        after = opts[:after]
        @rules ||= {}
        (@rules[after] ||= []) << opts

        unless @rules[after].length > 1
          if self.singleton_methods.include?(after)
            inject_class_methods(after)
          else
            inject_instance_methods(after)
          end
        end
      end

      def inject_instance_methods(after)
        define_method("#{after}_with_inject") do |*args|
          hash = send("#{after}_without_inject".to_sym, *args)
          self.class.instance_variable_get(:@rules)[after].each do |opts|
            if opts[:at].nil? or opts[:at].is_a? String
              hash = self.class.update_using_json_path(hash, opts)
            else
              self.class.inject_attributes_at(hash[opts[:at]], opts)
            end
          end
          hash
        end
        alias_method_chain after, :inject
      end

      def inject_class_methods(after)
        define_singleton_method("#{after}_with_inject") do |*args|
          hash = send("#{after}_without_inject".to_sym, *args)
          @rules[after].each do |opts|
            if opts[:at].nil? or opts[:at].is_a? String
              hash = update_using_json_path(hash, opts)
            else
              inject_attributes_at(hash[opts[:at]], opts)
            end
          end
          hash
        end
        self.singleton_class.send(:alias_method_chain, after, :inject)
      end

      def inject_attributes_at(hash_offset, opts)
        return hash_offset if hash_offset.nil? or hash_offset.empty?
        keys = hash_offset[opts[:using]]
        entity_name = __entity__(opts[:bucket_name] || opts[:using])
        values = Looksist.redis_service.send("#{entity_name}_for", keys)
        if opts[:populate].is_a? Array
          opts[:populate].each do |elt|
            value_hash = values.each_with_object([]) do |i, acc|
              acc << JSON.parse(i || '{}').deep_symbolize_keys[elt]
            end
            alias_method = find_alias(opts[:as], elt)
            hash_offset[alias_method] = value_hash
          end
        else
          alias_method = find_alias(opts[:as], opts[:populate])
          hash_offset[alias_method] = values
          hash_offset
        end
      end

      def update_using_json_path(hash, opts)
        if hash.is_a?(Hash)
          if opts[:at].present?
            JsonPath.for(hash.with_indifferent_access).gsub!(opts[:at]) do |i|
              i.is_a?(Array) ? inject_attributes_for(i, opts) : inject_attributes_at(i, opts) unless (i.nil? or i.empty?)
              i
            end
          else
            inject_attributes_at(hash, opts)

          end.to_hash.deep_symbolize_keys
        else
          inject_attributes_for_array(hash, opts)
        end
      end

      def inject_attributes_for(array_of_hashes, opts)
        entity_name = __entity__(opts[:bucket_name] || opts[:using])
        keys = (array_of_hashes.collect { |i| i[opts[:using]] }).compact.uniq
        values = Hash[keys.zip(Looksist.redis_service.send("#{entity_name}_for", keys))]
        opts[:populate].is_a?(Array) ? composite_attribute_lookup(array_of_hashes, opts, values) : single_attribute_lookup(array_of_hashes, opts, values)
      end

      def inject_attributes_for_array(array_of_hashes, opts)
        entity_name = __entity__(opts[:bucket_name] || opts[:using])
        modified_array = if opts[:at].nil?
                           array_of_hashes.map(&:values)
                         else
                           json_path = JsonPath.new("#{opts[:at]}..#{opts[:using]}")
                           json_path.on(array_of_hashes.to_json)
                         end
        keys = modified_array.flatten.compact.uniq
        values = Hash[keys.zip(Looksist.redis_service.send("#{entity_name}_for", keys))]
        opts[:populate].is_a?(Array) ? composite_attribute_lookup(array_of_hashes, opts, values) : single_attribute_lookup_for_array(array_of_hashes, opts, values)
      end

      def single_attribute_lookup(array_of_hashes, opts, values)
        array_of_hashes.each do |elt|
          alias_method = find_alias(opts[:as], opts[:populate])
          elt[alias_method] = values[elt[opts[:using]]]
        end
      end

      def single_attribute_lookup_for_array(array_of_hashes, opts, values)
        array_of_hashes.collect do |elt|
          alias_method = find_alias(opts[:as], opts[:populate])
          if opts[:at].present?
            JsonPath.for(elt.with_indifferent_access).gsub!(opts[:at]) do |node|
              if node.is_a? Array
                node.each { |x| x[alias_method] = values[x.with_indifferent_access[opts[:using]]] }
              else
                node[alias_method] = values[node.with_indifferent_access[opts[:using]]]
              end
              node
            end.to_hash.deep_symbolize_keys
          else
            elt[alias_method] = values[elt[opts[:using]]]
            elt
          end
        end
      end

      def composite_attribute_lookup(array_of_hashes, opts, values)
        array_of_hashes.collect do |elt|
          if opts[:at].present?
            JsonPath.for(elt.with_indifferent_access).gsub!(opts[:at]) do |node|
              if node.is_a? Array
                node.collect do |x|
                  opts[:populate].collect do |_key|
                    alias_method = find_alias(opts[:as], _key)
                    parsed_key = JSON.parse(values[x.with_indifferent_access[opts[:using]]]).deep_symbolize_keys
                    x[alias_method] = parsed_key[_key]
                  end
                end
              else
                parsed_key = JSON.parse(values[node.with_indifferent_access[opts[:using]]]).deep_symbolize_keys
                opts[:populate].collect do |_key|
                  alias_method = find_alias(opts[:as], _key)
                  node[alias_method] = parsed_key[_key]
                end
              end
              node
            end.to_hash.deep_symbolize_keys
          else
            parsed_key = JSON.parse(values[elt[opts[:using]]]).deep_symbolize_keys
            opts[:populate].collect do |_key|
              alias_method = find_alias(opts[:as], _key)
              elt[alias_method] = parsed_key[_key]
            end
            elt
          end
        end
      end

      def __entity__(entity)
        entity.to_s.gsub('_id', '')
      end

    end

    included do |base|
      base.class_attribute :rules
      base.rules = {}
    end


  end
end
