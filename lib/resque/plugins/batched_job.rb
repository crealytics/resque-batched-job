module Resque

  # This is a small wrapper around Resque.enqueue.
  # @param [Class] klass Job class.
  # @param [Object, #to_s] bid Batch identifier.
  def self.enqueue_batched_job(klass, bid, *args)
    Resque.enqueue(klass, bid, *args)
  end

  module Plugin

    # This hook is really the meaning of our adventure.
    def after_batch_hooks(job)
      job.methods.grep(/^after_batch/).sort
    end

  end

  module Plugins

    module BatchedJob

      include Resque::Helpers

      AFTER_BATCH_HOOKS_POTENTIALLY_IN_PROGRESS = 'after_batch_hooks_potentially_in_progress'
      EXPIRATION = 24 * 60 * 60

      # Helper method used to generate the batch key.
      #
      # @param [Object, #to_s] id Batch identifier. Any Object that responds to #to_s
      # @return [String] Used to identify batch Redis List key
      def batch(id)
        "batch:#{id}"
      end

      # Resque hook that handles batching the job. (closes #2)
      #
      # @param [Object, #to_s] id Batch identifier. Any Object that responds to #to_s
      def after_enqueue_batch(id, *args)
        mutex(id) do |bid|
          redis.rpush(bid, encode(:class => self.name, :args => args))
        end
      end

      # After the job is performed, remove it from the batched job list.  If the
      # current job is the last in the batch to be performed, invoke the after_batch
      # hooks.
      #
      # @param id (see Resque::Plugins::BatchedJob#after_enqueue_batch)
      def after_perform_batch(id, *args)
        mutex(id) do |bid|
          redis.setex("#{bid}:#{AFTER_BATCH_HOOKS_POTENTIALLY_IN_PROGRESS}", EXPIRATION, 'true')
        end

        begin
          if remove_batched_job(id, *args) == 0
            after_batch_hooks = Resque::Plugin.after_batch_hooks(self)
            after_batch_hooks.each do |hook|
              send(hook, id, *args)
            end
          end
        ensure
          mutex(id) do |bid|
            redis.del("#{bid}:#{AFTER_BATCH_HOOKS_POTENTIALLY_IN_PROGRESS}")
          end
        end
      end

      # After a job is removed, also remove it from the batch.
      #
      # @param id (see Resque::Plugins::BatchedJob#after_enqueue_batch)
      def after_dequeue_batch(id, *args)
        remove_batched_job(id, *args)
      end

      # Checks the size of the batched job list and returns true if the list is
      # empty or if the key does not exist.
      #
      # @param id (see Resque::Plugins::BatchedJob#batch)
      def batch_complete?(id)
        mutex(id) do |bid|
          redis.llen(bid) == 0 && !redis.exists("#{bid}:#{AFTER_BATCH_HOOKS_POTENTIALLY_IN_PROGRESS}")
        end
      end

      # Check to see if the Redis key exists.
      #
      # @param id (see Resque::Plugins::BatchedJob#batch)
      def batch_exist?(id)
        mutex(id) do |bid|
          redis.exists(bid)
        end
      end

      # Remove a job from the batch list. (closes #6)
      #
      # @param id (see Resque::Plugins::BatchedJob#after_enqueue_batch)
      def remove_batched_job(id, *args)
        mutex(id) do |bid|
          redis.lrem(bid, 1, encode(:class => self.name, :args => args))
          redis.llen(bid)
        end
      end

      # Remove a job from the batch list and run after hooks if necessary.
      #
      # @param id (see Resque::Plugins::BatchedJob#remove_batched_job)
      def remove_batched_job!(id, *args)
        after_perform_batch(id, *args)
      end

      private

        # Lock a batch key before executing Redis commands.  This will ensure
        # no race conditions occur when modifying batch information.  Here is
        # an example of how this works.  See http://redis.io/commands/setnx for
        # more information. (fixes #4) (closes #5)
        #
        # * Job2 sends SETNX batch:123:lock in order to aquire a lock.
        # * Job1 still has the key locked, so Job2 continues into the loop.
        # * Job2 sends GET to aquire the lock timestamp.
        # * If the timestamp does not exist (Job1 released the lock), Job2
        #   attemps to start from the beginning again.
        # * If the timestamp exists and has not expired, Job2 sleeps for a
        #   moment and then retries from the start.
        # * If the timestamp exists and has expired, Job2 sends GETSET to aquire
        #   a lock.  This returns the previous value of the lock.
        # * If the previous timestamp has not expired, another process was faster
        #   and aquired the lock.  This means Job2 has to start from the beginnig.
        # * If the previous timestamp is still expired the lock has been set and
        #   processing can continue safely
        #
        # @param id (see Resque::Plugins::BatchedJob#batch)
        # @yield [bid] Yields the current batch id.
        # @yieldparam [String] The current batch id.
        def mutex(id, &block)
          is_expired = lambda do |locked_at|
            locked_at.to_f < Time.now.to_f
          end
          bid   = batch(id)
          _key_ = "#{bid}:lock"

          until redis.setnx(_key_, Time.now.to_f + 0.5)
            next unless timestamp = redis.get(_key_)

            unless is_expired.call(timestamp)
              sleep(0.1)
              next
            end

            break unless timestamp = redis.getset(_key_, Time.now.to_f + 0.5)
            break if is_expired.call(timestamp)
          end
          yield(bid)
        ensure
          redis.del(_key_)
        end

    end

  end

end
