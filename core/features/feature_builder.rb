# frozen_string_literal: true

module GK
  module Core
    module Features
      # Thin wrapper to unify feature-building entrypoint for train/predict paths.
      class FeatureBuilder
        def self.from_block(&block)
          raise ArgumentError, "block is required" unless block

          new(adapter: block)
        end

        def initialize(adapter:)
          raise ArgumentError, "adapter must respond to call" unless adapter.respond_to?(:call)

          @adapter = adapter
        end

        def build(**kwargs)
          @adapter.call(**kwargs)
        end
      end
    end
  end
end
