require 'glib2'

require "rabbit/logger/base"

module Rabbit
  module Logger
    class STDERR
      include Base

      private
      def do_log(severity, prog_name, message)
        # TODO: Remove me. It is workaround until Ruby/GLib2 2.0.3 is released.
        if message.encoding == Encoding::ASCII_8BIT
          message.force_encoding("UTF-8")
        end
        begin
          message = message.encode("locale")
        rescue EncodingError
          format = _("can't convert to current locale from UTF-8: %s")
          ::STDERR.puts(format % message)
        end
        ::STDERR.puts(format_severity(severity))
        ::STDERR.print("[#{prog_name}]: ") if prog_name
        ::STDERR.puts(message)
        exit if severity >= Severity::FATAL
      end
    end
  end
end
