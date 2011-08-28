private bool debug_enabled = false;

private string replace_extension (string filename, string extension)
{
    var i = filename.last_index_of_char ('.');
    if (i < 0)
        return "%s.%s".printf (filename, extension);

    return "%.*s.%s".printf (i, filename, extension);
}

public class Rule
{
    public List<string> inputs;
    public List<string> outputs;
    public List<string> commands;
    
    private TimeVal? get_modification_time (string filename) throws Error
    {
        var f = File.new_for_path (filename);
        var info = f.query_info (FILE_ATTRIBUTE_TIME_MODIFIED, FileQueryInfoFlags.NONE);

        GLib.TimeVal modification_time;
        info.get_modification_time (out modification_time);

        return modification_time;
    }
    
    private static int timeval_cmp (TimeVal a, TimeVal b)
    {
        if (a.tv_sec == b.tv_sec)
            return (int) (a.tv_usec - b.tv_usec);
        else
            return (int) (a.tv_sec - b.tv_sec);
    }
    
    public bool needs_build ()
    {
       TimeVal max_input_time = { 0, 0 };
       foreach (var filename in inputs)
       {
           TimeVal modification_time;
           try
           {
               modification_time = get_modification_time (filename);
           }
           catch (Error e)
           {
               warning ("Unable to access input file %s: %s", filename, e.message);
               return false;
           }
           if (timeval_cmp (modification_time, max_input_time) > 0)
               max_input_time = modification_time;
       }

       var do_build = false;
       foreach (var filename in outputs)
       {
           TimeVal modification_time;
           try
           {
               modification_time = get_modification_time (filename);
           }
           catch (Error e)
           {
               // FIXME: Only if opened
               do_build = true;
               continue;
           }
           if (timeval_cmp (modification_time, max_input_time) < 0)
              do_build = true;
       }

       return do_build;
    }

    public bool build ()
    {
       foreach (var c in commands)
       {
           print ("    %s\n", c);
           var exit_status = Posix.system (c);
           if (Process.if_signaled (exit_status))
           {
               printerr ("Build stopped with signal %d\n", Process.term_sig (exit_status));
               return false;
           }
           if (Process.if_exited (exit_status) && Process.exit_status (exit_status) != 0)
           {
               printerr ("Build stopped with return value %d\n", Process.exit_status (exit_status));               
               return false;
           }
       }

       return true;
    }
}

public class BuildFile
{
    public string dirname;
    public List<BuildFile> children;
    public HashTable<string, string> variables;
    public List<string> programs;
    public List<Rule> rules;

    public BuildFile (string filename) throws FileError
    {
        dirname = Path.get_dirname (filename);

        var dir = Dir.open (dirname);
        while (true)
        {
            var child_dir = dir.read_name ();
            if (child_dir == null)
                 break;

            var child_filename = Path.build_filename (dirname, child_dir, "Buildfile");
            if (FileUtils.test (child_filename, FileTest.EXISTS))
            {
                if (debug_enabled)
                    debug ("Loading %s", child_filename);
                children.append (new BuildFile (child_filename));
            }
        }

        variables = new HashTable<string, string> (str_hash, str_equal);
        string contents;
        FileUtils.get_contents (filename, out contents);
        var lines = contents.split ("\n");
        var in_rule = false;
        string? rule_indent = null;
        foreach (var line in lines)
        {
            var i = 0;
            while (line[i].isspace ())
                i++;
            var indent = line.substring (0, i);
            var statement = line.substring (i);

            statement = statement.chomp ();

            if (in_rule)
            {
                if (rule_indent == null)
                    rule_indent = indent;

                if (indent == rule_indent)
                {
                    var rule = rules.last ().data;
                    rule.commands.append (statement);
                    continue;
                }
                in_rule = false;
            }

            if (statement == "")
                continue;
            if (statement.has_prefix ("#"))
                continue;

            var index = statement.index_of ("=");
            if (index > 0)
            {
                var name = statement.substring (0, index).chomp ();
                variables.insert (name, statement.substring (index + 1).strip ());

                var tokens = name.split (".");
                if (tokens.length > 1 && tokens[0] == "programs")
                {
                    var program_name = tokens[1];
                    var has_name = false;
                    foreach (var p in programs)
                    {
                        if (p == program_name)
                        {
                            has_name = true;
                            break;
                        }
                    }
                    if (!has_name)
                        programs.append (program_name);
                }

                continue;
            }

            index = statement.index_of (":");
            if (index > 0)
            {
                var rule = new Rule ();
                foreach (var output in statement.substring (0, index).chomp ().split (" "))
                    rule.outputs.append (output);
                foreach (var input in statement.substring (index + 1).strip ().split (" "))
                    rule.inputs.append (input);
                rules.append (rule);
                in_rule = true;
                continue;
            }

            debug ("Unknown statement '%s'", statement);
            //return Posix.EXIT_FAILURE;
        }

        /* Make rules */
        foreach (var program in programs)
        {
            var source_list = variables.lookup ("programs.%s.sources".printf (program));
            if (source_list == null)
                continue;

            var sources = source_list.split (" ");

            var package_list = variables.lookup ("programs.%s.packages".printf (program));
            var cflags = variables.lookup ("programs.%s.cflags".printf (program));
            var ldflags = variables.lookup ("programs.%s.ldflags".printf (program));

            string? package_cflags = null;
            string? package_ldflags = null;
            if (package_list != null)
            {
                int exit_status;
                try
                {
                    Process.spawn_command_line_sync ("pkg-config --cflags %s".printf (package_list), out package_cflags, null, out exit_status);
                    package_cflags = package_cflags.strip ();
                }
                catch (SpawnError e)
                {
                }
                try
                {
                    Process.spawn_command_line_sync ("pkg-config --libs %s".printf (package_list), out package_ldflags, null, out exit_status);
                    package_ldflags = package_ldflags.strip ();
                }
                catch (SpawnError e)
                {
                }
            }

            /* Vala compile */
            var rule = new Rule ();
            var command = "valac -C";
            if (package_list != null)
            {
                foreach (var package in package_list.split (" "))
                    command += " --pkg %s".printf (package);
            }
            foreach (var source in sources)
            {
                if (!source.has_suffix (".vala") && !source.has_suffix (".vapi"))
                    continue;

                rule.inputs.append (source);
                if (source.has_suffix (".vala"))
                    rule.outputs.append (replace_extension (source, "c"));
                command += " %s".printf (source);
            }
            if (rule.outputs != null)
            {
                rule.commands.append (command);
                rules.append (rule);
            }

            /* C compile */
            foreach (var source in sources)
            {
                if (!source.has_suffix (".vala") && !source.has_suffix (".c"))
                    continue;

                var input = replace_extension (source, "c");
                var output = replace_extension (source, "o");

                rule = new Rule ();
                rule.inputs.append (input);
                rule.outputs.append (output);
                command = "gcc -g -Wall";
                if (cflags != null)
                    command += " %s".printf (cflags);
                if (package_cflags != null)
                    command += " %s".printf (package_cflags);
                command += " -c %s -o %s".printf (input, output);
                rule.commands.append (command);
                rules.append (rule);
            }

            /* Link */
            rule = new Rule ();
            foreach (var source in sources)
            {
                if (source.has_suffix (".vala") || source.has_suffix (".c"))
                    rule.inputs.append (replace_extension (source, "o"));
            }
            rule.outputs.append (program);
            command = "gcc -g -Wall";
            foreach (var source in sources)
            {
                if (source.has_suffix (".vala") || source.has_suffix (".c"))
                    command += " %s".printf (replace_extension (source, "o"));
            }
            if (ldflags != null)
                command += " %s".printf (ldflags);
            if (package_ldflags != null)
                command += " %s".printf (package_ldflags);
            command += " -o %s".printf (program);
            rule.commands.append (command);
            rules.append (rule);
        }
    }

    public Rule? find_rule (string output)
    {
        foreach (var r in rules)
        {
            foreach (var o in r.outputs)
                if (o == output)
                    return r;
        }

        return null;
    }

    private bool build_file (string output)
    {
        var rule = find_rule (output);
        if (rule != null)
        {
            foreach (var input in rule.inputs)
            {
                if (!build_file (input))
                    return false;
            }

            if (rule.needs_build ())
            {
                GLib.print ("\x1B[1m[Building %s]\x1B[21m\n", output);
                if (!rule.build ())
                    return false;
            }
        }

        if (!FileUtils.test (output, FileTest.EXISTS))
        {
            GLib.print ("File %s does not exist\n", output);
            return false;
        }

        return true;
    }
    
    public bool build ()
    {
        foreach (var child in children)
        {
            if (!child.build ())
                return false;
        }

        Environment.set_current_dir (dirname);
        if (debug_enabled)
            debug ("Entering directory %s", dirname);
        foreach (var program in programs)
        {
            if (!build_file (program))
                return false;
        }

        return true;
    }

    public void clean ()
    {
        foreach (var child in children)
            child.clean ();

        Environment.set_current_dir (dirname);
        if (debug_enabled)
            debug ("Entering directory %s", dirname);
        foreach (var r in rules)
        {
            foreach (var output in r.outputs)
            {
                var result = FileUtils.unlink (output);
                if (result >= 0) // FIXME: Report errors
                    GLib.print ("\x1B[1m[Removed %s]\x1B[21m\n".printf (output));
            }
        }
    }

    public void print ()
    {
        foreach (var name in variables.get_keys ())
            GLib.print ("%s=%s\n", name, variables.lookup (name));
        foreach (var r in rules)
        {
            foreach (var output in r.outputs)
                GLib.print ("%s ", output);
            GLib.print (":");
            foreach (var input in r.inputs)
                GLib.print (" %s", input);
            GLib.print ("\n");
            foreach (var c in r.commands)
                GLib.print ("    %s\n", c);
        }
    }
}

public class EasyBuild
{
    private static bool show_version = false;
    public static const OptionEntry[] options =
    {
        { "version", 'v', 0, OptionArg.NONE, ref show_version,
          /* Help string for command line --version flag */
          N_("Show release version"), null},
        { "debug", 'd', 0, OptionArg.NONE, ref debug_enabled,
          /* Help string for command line --debug flag */
          N_("Print debugging messages"), null},
        { null }
    };

    public static int main (string[] args)
    {
        var c = new OptionContext (/* Arguments and description for --help text */
                                   _("[COMMAND] - Build system"));
        c.add_main_entries (options, Config.GETTEXT_PACKAGE);
        try
        {
            c.parse (ref args);
        }
        catch (Error e)
        {
            stderr.printf ("%s\n", e.message);
            stderr.printf (/* Text printed out when an unknown command-line argument provided */
                           _("Run '%s --help' to see a full list of available command line options."), args[0]);
            stderr.printf ("\n");
            return Posix.EXIT_FAILURE;
        }
        if (show_version)
        {
            /* Note, not translated so can be easily parsed */
            stderr.printf ("easy-build %s\n", Config.VERSION);
            return Posix.EXIT_SUCCESS;
        }

        BuildFile f;
        var filename = Path.build_filename (Environment.get_current_dir (), "Buildfile");
        if (debug_enabled)
            debug ("Loading %s", filename);
        try
        {
            f = new BuildFile (filename);
        }
        catch (FileError e)
        {
            printerr ("Failed to load Buildfile: %s\n", e.message);
            return Posix.EXIT_FAILURE;
        }
        //f.print ();

        string command = "build";
        if (args.length >= 2)
            command = args[1];

        switch (command)
        {
        case "build":
            /*if (debug_enabled)
            {
               f.print ();
               GLib.print ("\n\n");
            }*/
            if (!f.build ())
                return Posix.EXIT_FAILURE;
            break;

        case "clean":
            f.clean ();
            break;

        default:
            printerr ("Unknown command %s\n", command);
            break;
        }

        return Posix.EXIT_SUCCESS;
    }
}
