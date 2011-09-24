public class ManModule : BuildModule
{
    public override void generate_rules (BuildFile build_file)
    {
        var man_page_list = build_file.variables.lookup ("man.pages");
        if (man_page_list != null)
        {
            var pages = man_page_list.split (" ");
            foreach (var page in pages)
            {
                var i = page.last_index_of_char ('.');
                var number = 0;
                if (i > 0)
                    number = int.parse (page.substring (i + 1));
                if (number == 0)
                {
                    warning ("Not a valid man page name '%s'", page);
                    continue;
                }
                build_file.install_rule.inputs.append (page);
                var dir = "%s/man/man%d".printf  (data_directory, number);
                build_file.install_rule.commands.append ("@mkdir -p %s".printf (get_install_directory (dir)));
                build_file.install_rule.commands.append ("@install %s %s/%s".printf (page, get_install_directory (dir), page));
            }
        }
    }
}