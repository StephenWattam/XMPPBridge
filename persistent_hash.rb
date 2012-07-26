# Manages a hash - derived settings object.
# This settings object may be set to be thread-safe.

require 'yaml'
require 'thread'

class PersistentHash < Hash
  def initialize(filename=nil, loadfile=false, initial_value=nil)
    super(initial_value)
    @mutex = Mutex.new
    @filename = filename

    if File.exist?(filename) and loadfile
      load(true)
    end
  end

  # save to a file other than the filename
  def save_as(path, overwrite=true)
    write_file(overwrite, path)
  end

  # save to the internal filename deely.
  def save(overwrite=true)
    write_file(overwrite, @filename)
  end

  # internal save method
  def write_file(overwrite=false, path=nil)
    @mutex.synchronize{
      # get the filepath internally, prefer argument
      filepath = path or @filename
      raise "Nowhere to save" if not filepath

      # check overwrite status
      raise "A file exists already.  Use overwrite=true to clobber" if File.exist?(filepath) and not overwrite

      # write the file
      File.open( filepath, 'w' ) do |out|
        dump = Hash.new()
        keys.each{ |k| dump[k] = self[k] }

        YAML.dump( dump, out )
      end

      # update thingy
      @filename = filepath
    }
  end

  def load(clear=true, filename = @filename)
    @mutex.synchronize{
      @filename = filename

      hash = YAML.load_file( filename )
      self.clear if clear
      self.merge!(hash)
    }
  end

  # Mutex and passthrough
  def method_missing(name, *args, &block)
    if(block) then
      @mutex.synchronize{
        super.method(name).call(*args)
      }
    else
      @mutex.synchronize{
        super.method(name).call(*args){|*x| block.call(*x) }
      }
    end
  end

end




## test script
#x = SettingsManager.new(nil, 'test')
#x[4] = "test"
#x[5] = "test"
#x[6] = "test"
#x.save



#y = SettingsManager.new( nil, "test", true )
##y.save
#y.save_as( "test2" )
