require "forwardable"
require "gtk2"
require "rd/rdfmt"
require "rexml/text"

require "rabbit/rd2rabbit-lib"
require "rabbit/theme"
require "rabbit/element"
require "rabbit/index"

module Rabbit

  class Frame

    extend Forwardable
    
    def_delegators(:@window, :icon, :icon=, :set_icon)
    def_delegators(:@window, :icon_list, :icon_list=, :set_icon_list)
    def_delegators(:@window, :fullscreen, :unfullscreen)
    def_delegators(:@window, :iconify)
    def_delegators(:@canvas, :apply_theme, :theme_name)
    def_delegators(:@canvas, :saved_image_type=, :saved_image_basename=)
    def_delegators(:@canvas, :save_as_image)
    
    attr_reader :window, :canvas

    def initialize(width, height, main_window=true)
      init_window(width, height)
      init_canvas
      @fullscreen = false
      @iconify = false
      @main_window = main_window
      @window.show_all
    end

    def quit
      @window.destroy
      true
    end

    def width
      @window.size[0]
    end

    def height
      @window.size[1]
    end

    def parse_rd(source)
      @canvas.parse_rd(source)
    end

    def toggle_fullscreen
      if fullscreen?
        @fullscreen = false
        unfullscreen
      else
        @fullscreen = true
        fullscreen
      end
    end

    def fullscreen?
      if @window.respond_to?(:fullscreen?)
        @window.fullscreen?
      else
        @fullscreen
      end
    end

    def main_window?
      @main_window
    end
    
    def update_title(new_title)
      @window.title = unescape_title(new_title)
    end

    private
    def init_window(width, height)
      @window = Gtk::Window.new
      @window.set_default_size(width, height)
      @window.set_app_paintable(true)
      set_window_signal
    end

    def set_window_signal
      set_window_signal_window_state_event
      set_window_signal_destroy
    end

    def set_window_signal_window_state_event
      @window.signal_connect("window_state_event") do |widget, event|
        if event.changed_mask.fullscreen?
          if fullscreen?
            @canvas.fullscreened
          else
            @canvas.unfullscreened
          end
        elsif event.changed_mask.iconified?
          if @iconify
            @iconify = false
          else
            @canvas.iconified
            @iconify = true
          end
        end
      end
    end

    def set_window_signal_destroy
      @window.signal_connect("destroy") do
        @canvas.destroy
        Gtk.main_quit if main_window?
      end
    end

    def init_canvas
      @canvas = Canvas.new(self)
      @window.add(@canvas.drawing_area)
    end

    def unescape_title(title)
      REXML::Text.unnormalize(title).gsub(/\r|\n/, '')
    end

  end

  class Canvas
    
    include Enumerable
    extend Forwardable

    def_delegators(:@frame, :icon, :icon=, :set_icon)
    def_delegators(:@frame, :icon_list, :icon_list=, :set_icon_list)
    def_delegators(:@frame, :quit)
    
    attr_reader :drawing_area, :drawable, :foreground, :background
    attr_reader :theme_name, :font_families
    attr_reader :source

    attr_writer :saved_image_basename

    attr_accessor :saved_image_type


    def initialize(frame)
      @frame = frame
      @pages = []
      @index_pages = []
      @index_mode = false
      @index_current_index = 0
      @current_index = 0
      @theme_name = nil
      @blank_cursor = nil
      @saved_image_basename
      init_drawing_area
      layout = @drawing_area.create_pango_layout("")
      @font_families = layout.context.list_families
    end

    def title
      title_page.title
    end

    def page_title
      page = current_page
      if page.is_a?(Element::TitlePage)
        page.title
      else
        "#{title}: #{page.title}"
      end
    end

    def width
      @drawable.size[0]
    end

    def height
      @drawable.size[1]
    end

    def pages
      if @index_mode
        @index_pages
      else
        @pages
      end
    end
    
    def page_size
      pages.size
    end

    def destroy
      @drawing_area.destroy
    end

    def current_page
      pages[current_index]
    end

    def current_index
      if @index_mode
        @index_current_index
      else
        @current_index
      end
    end

    def next_page
      pages[current_index + 1]
    end

    def each(&block)
      pages.each(&block)
    end

    def <<(page)
      pages << page
    end

    def apply_theme(name=nil)
      @theme_name = name || @theme_name || default_theme
      if @theme_name and not @pages.empty?
        clear_theme
        clear_index_pages
        @index_mode = false
        theme = Theme.new(self)
        theme.apply(@theme_name)
        @drawing_area.queue_draw
      end
    end

    def reload_theme
      apply_theme
    end

    def parse_rd(source=nil)
      @source = source || @source
      if @source.modified?
        begin
          tree = RD::RDTree.new("=begin\n#{@source.read}\n=end\n")
          @pages.clear
          clear_index_pages
          visitor = RD2RabbitVisitor.new(self)
          visitor.visit(tree)
          apply_theme
          @frame.update_title(title)
        rescue Racc::ParseError
          puts $!.message
        end
      end
    end

    def reload_source
      if need_reload_source?
        parse_rd
      end
    end

    def need_reload_source?
      @source and @source.modified?
    end

    def base
      @source and @source.base
    end

    def set_foreground(color)
      @foreground.set_foreground(color)
    end

    def set_background(color)
      @background.set_foreground(color)
      @drawable.background = color
    end

    def save_as_image
      file_name_format =
          "#{saved_image_basename}%0#{number_of_places(page_size)}d.#{@saved_image_type}"
      each_page_pixbuf do |pixbuf, page_number|
        file_name = file_name_format % page_number
        pixbuf.save(file_name, normalized_saved_image_type)
      end
    end
    
    def each_page_pixbuf
      args = [@drawable, 0, 0, width, height]
      before_page_index = current_index
      pages.each_with_index do |page, i|
        move_to(i)
        @drawable.process_updates(true)
        yield(Gdk::Pixbuf.from_drawable(@drawable.colormap, *args), i)
      end
      move_to(before_page_index)
    end
    
    def fullscreened
      @drawable.cursor = blank_cursor
    end

    def unfullscreened
      @drawable.cursor = nil
    end

    def iconified
      # do nothing
    end

    def saved_image_basename
      @saved_image_basename || GLib.filename_from_utf8(title)
    end

    def redraw
      @drawing_area.queue_draw
    end

    private
    def title_page
      @pages.find{|x| x.is_a?(Element::TitlePage)}
    end

    def default_theme
      tp = title_page
      tp and tp.theme
    end

    def init_drawing_area
      @drawing_area = Gtk::DrawingArea.new
      @drawing_area.set_can_focus(true)
      @drawing_area.add_events(Gdk::Event::BUTTON_PRESS_MASK)
      set_realize
      set_key_press_event
      set_button_press_event
      set_expose_event
    end

    def set_realize
      @drawing_area.signal_connect("realize") do |widget, event|
        @drawable = widget.window
        @foreground = Gdk::GC.new(@drawable)
        @background = Gdk::GC.new(@drawable)
        @background.set_foreground(widget.style.bg(Gtk::STATE_NORMAL))
      end
    end

    def set_key_press_event
      @drawing_area.signal_connect("key_press_event") do |widget, event|
        handled = false
        
        if event.state.control_mask?
          handled = handle_key_with_control(event)
        end
        
        unless handled
          handle_key(event)
        end
      end
    end

    def set_button_press_event
      @drawing_area.signal_connect("button_press_event") do |widget, event|
        case event.button
        when 1
          move_to_next_if_can
        when 2
          move_to_previous_if_can
        when 3
        end
      end
    end

    def set_expose_event
      prev_width = prev_height = nil
      @drawing_area.signal_connect("expose_event") do |widget, event|
        reload_source
        if @drawable
          if prev_width.nil? or prev_height.nil? or
              [prev_width, prev_height] != [width, height]
            clear_index_pages
            reload_theme
            prev_width, prev_height = width, height
          end
        end
        page = current_page
        if page
          page.draw(self)
#           if next_page
#             next_page.draw(self, true)
#           end
          @frame.update_title(page_title)
        end
      end
    end

    def set_current_index(new_index)
      if @index_mode
        @index_current_index = new_index
      else
        @current_index = new_index
      end
    end

    def with_index_mode(new_value)
      current_index_mode = @index_mode
      @index_mode = new_value
      yield
      @index_mode = current_index_mode
    end
    
    def move_to(index)
      set_current_index(index)
      @frame.update_title(page_title)
      @drawing_area.queue_draw
    end

    def move_to_if_can(index)
      if index < page_size
        move_to(index)
      end
    end

    def move_to_next_if_can
      if current_index + 1 < page_size
        move_to(current_index + 1)
      end
    end

    def move_to_previous_if_can
      if current_index > 0
        move_to(current_index - 1)
      end
    end

    def move_to_first
      move_to(0)
    end

    def move_to_last
      move_to(page_size - 1)
    end

    def calc_page_number(key_event, base)
      val = key_event.keyval
      val += 10 if key_event.state.control_mask?
      val += 20 if key_event.state.mod1_mask?
      val - base
    end

    def clear_theme
      @pages.each do |page|
        page.clear_theme
      end
    end

    def normalized_saved_image_type
      case @saved_image_type
      when /jpg/i
        "jpeg"
      else
        @saved_image_type.downcase
      end
    end

    def blank_cursor
      if @blank_cursor.nil?
        source = Gdk::Pixmap.new(@drawable, 1, 1, 1)
        mask = Gdk::Pixmap.new(@drawable, 1, 1, 1)
        fg = @foreground.foreground
        bg = @background.foreground
        @blank_cursor = Gdk::Cursor.new(source, mask, fg, bg, 1, 1)
      end
      @blank_cursor
    end

    def toggle_index_mode
      if @index_mode
        @index_mode = false
      else
        @index_mode = true
        @index_current_index = 0
        if @index_pages.empty?
          @index_pages = Index.make_index_pages(self)
        end
      end
      @drawing_area.queue_draw
    end

    def clear_index_pages
      @index_current_index = 0
      @index_pages.clear
    end

    def number_of_places(num)
      n = 1
      target = num
      while target >= 10
        target /= 10
        n += 1
      end
      n
    end

    def handle_key(key_event)
      case key_event.keyval
      when Gdk::Keyval::GDK_Escape, Gdk::Keyval::GDK_q
        quit
      when Gdk::Keyval::GDK_n,
      Gdk::Keyval::GDK_f,
      Gdk::Keyval::GDK_j,
      Gdk::Keyval::GDK_l,
      Gdk::Keyval::GDK_Page_Down,
      Gdk::Keyval::GDK_Tab,
      Gdk::Keyval::GDK_Return,
      Gdk::Keyval::GDK_rightarrow,
      Gdk::Keyval::GDK_downarrow,
      Gdk::Keyval::GDK_space,
      Gdk::Keyval::GDK_plus,
      Gdk::Keyval::GDK_Right,
      Gdk::Keyval::GDK_Down,
      Gdk::Keyval::GDK_KP_Add,
      Gdk::Keyval::GDK_KP_Right,
      Gdk::Keyval::GDK_KP_Down,
      Gdk::Keyval::GDK_KP_Page_Down,
      Gdk::Keyval::GDK_KP_Enter,
      Gdk::Keyval::GDK_KP_Tab
        move_to_next_if_can
      when Gdk::Keyval::GDK_p,
      Gdk::Keyval::GDK_b,
      Gdk::Keyval::GDK_h,
      Gdk::Keyval::GDK_k,
      Gdk::Keyval::GDK_Page_Up,
      Gdk::Keyval::GDK_leftarrow,
      Gdk::Keyval::GDK_uparrow,
      Gdk::Keyval::GDK_BackSpace,
      Gdk::Keyval::GDK_Delete,
      Gdk::Keyval::GDK_minus,
      Gdk::Keyval::GDK_Up,
      Gdk::Keyval::GDK_Left,
      Gdk::Keyval::GDK_KP_Subtract,
      Gdk::Keyval::GDK_KP_Up,
      Gdk::Keyval::GDK_KP_Left,
      Gdk::Keyval::GDK_KP_Page_Up,
      Gdk::Keyval::GDK_KP_Delete
        move_to_previous_if_can
      when Gdk::Keyval::GDK_a,
      Gdk::Keyval::GDK_Home,
      Gdk::Keyval::GDK_less
        move_to_first
      when Gdk::Keyval::GDK_e,
      Gdk::Keyval::GDK_End,
      Gdk::Keyval::GDK_greater
        move_to_last
      when Gdk::Keyval::GDK_0,
      Gdk::Keyval::GDK_1,
      Gdk::Keyval::GDK_2,
      Gdk::Keyval::GDK_3,
      Gdk::Keyval::GDK_4,
      Gdk::Keyval::GDK_5,
      Gdk::Keyval::GDK_6,
      Gdk::Keyval::GDK_7,
      Gdk::Keyval::GDK_8,
      Gdk::Keyval::GDK_9
        move_to_if_can(calc_page_number(key_event, Gdk::Keyval::GDK_0))
      when Gdk::Keyval::GDK_KP_0,
      Gdk::Keyval::GDK_KP_1,
      Gdk::Keyval::GDK_KP_2,
      Gdk::Keyval::GDK_KP_3,
      Gdk::Keyval::GDK_KP_4,
      Gdk::Keyval::GDK_KP_5,
      Gdk::Keyval::GDK_KP_6,
      Gdk::Keyval::GDK_KP_7,
      Gdk::Keyval::GDK_KP_8,
      Gdk::Keyval::GDK_KP_9
        move_to_if_can(calc_page_number(key_event, Gdk::Keyval::GDK_KP_0))
      when Gdk::Keyval::GDK_F10
        @frame.toggle_fullscreen
        reload_theme
      when Gdk::Keyval::GDK_t,
      Gdk::Keyval::GDK_r
        reload_theme
      when Gdk::Keyval::GDK_s
        save_as_image
      when Gdk::Keyval::GDK_z
        @frame.iconify
      when Gdk::Keyval::GDK_i
        toggle_index_mode
      end
    end

    def handle_key_with_control(key_event)
      handled = false
      case key_event.keyval
      when Gdk::Keyval::GDK_l
        redraw
        handled = true
      end
      handled
    end
    
  end

end
