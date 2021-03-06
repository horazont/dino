using Gee;

using Xmpp.Core;

namespace Xmpp.Xep.Muc {

private const string NS_URI = "http://jabber.org/protocol/muc";
private const string NS_URI_ADMIN = NS_URI + "#admin";
private const string NS_URI_USER = NS_URI + "#user";

public const string AFFILIATION_ADMIN = "admin";
public const string AFFILIATION_MEMBER = "member";
public const string AFFILIATION_NONE = "none";
public const string AFFILIATION_OUTCAST = "outcast";
public const string AFFILIATION_OWNER = "owner";

public const string ROLE_MODERATOR = "moderator";
public const string ROLE_NONE = "none";
public const string ROLE_PARTICIPANT = "participant";
public const string ROLE_VISITOR = "visitor";

public enum MucEnterError {
    PASSWORD_REQUIRED,
    NOT_IN_MEMBER_LIST,
    BANNED,
    NICK_CONFLICT,
    OCCUPANT_LIMIT_REACHED,
    ROOM_DOESNT_EXIST
}

public class Module : XmppStreamModule {
    public static ModuleIdentity<Module> IDENTITY = new ModuleIdentity<Module>(NS_URI, "0045_muc_module");

    public signal void received_occupant_affiliation(XmppStream stream, string jid, string? affiliation);
    public signal void received_occupant_jid(XmppStream stream, string jid, string? real_jid);
    public signal void received_occupant_role(XmppStream stream, string jid, string? role);
    public signal void subject_set(XmppStream stream, string subject, string jid);

    public void enter(XmppStream stream, string bare_jid, string nick, string? password, ListenerHolder.OnSuccess success_listener, ListenerHolder.OnError error_listener, Object? store) {
        Presence.Stanza presence = new Presence.Stanza();
        presence.to = bare_jid + "/" + nick;
        StanzaNode x_node = new StanzaNode.build("x", NS_URI).add_self_xmlns();
        if (password != null) {
            x_node.put_node(new StanzaNode.build("password", NS_URI).put_node(new StanzaNode.text(password)));
        }
        presence.stanza.put_node(x_node);

        stream.get_flag(Flag.IDENTITY).start_muc_enter(bare_jid, presence.id, new ListenerHolder(success_listener, error_listener, store));

        stream.get_module(Presence.Module.IDENTITY).send_presence(stream, presence);
    }

    public void exit(XmppStream stream, string jid) {
        string nick = stream.get_flag(Flag.IDENTITY).get_muc_nick(jid);
        Presence.Stanza presence = new Presence.Stanza();
        presence.to = jid + "/" + nick;
        presence.type_ = Presence.Stanza.TYPE_UNAVAILABLE;
        stream.get_module(Presence.Module.IDENTITY).send_presence(stream, presence);
    }

    public void change_subject(XmppStream stream, string jid, string subject) {
        Message.Stanza message = new Message.Stanza();
        message.to = jid;
        message.type_ = Message.Stanza.TYPE_GROUPCHAT;
        message.stanza.put_node((new StanzaNode.build("subject")).put_node(new StanzaNode.text(subject)));
        stream.get_module(Message.Module.IDENTITY).send_message(stream, message);
    }

    public void change_nick(XmppStream stream, string jid, string new_nick) {
        Presence.Stanza presence = new Presence.Stanza();
        presence.to = jid + "/" + new_nick;
        stream.get_module(Presence.Module.IDENTITY).send_presence(stream, presence);
    }

    public void kick(XmppStream stream, string jid, string nick) {
        change_role(stream, jid, nick, "none");
    }

    public override void attach(XmppStream stream) {
        stream.add_flag(new Muc.Flag());
        Message.Module.require(stream);
        stream.get_module(Message.Module.IDENTITY).received_message.connect(on_received_message);
        Presence.Module.require(stream);
        stream.get_module(Presence.Module.IDENTITY).received_presence.connect(on_received_presence);
        stream.get_module(Presence.Module.IDENTITY).received_available.connect(on_received_available);
        stream.get_module(Presence.Module.IDENTITY).received_unavailable.connect(on_received_unavailable);
        if (stream.get_module(ServiceDiscovery.Module.IDENTITY) != null) {
            stream.get_module(ServiceDiscovery.Module.IDENTITY).add_feature(stream, NS_URI);
        }
    }

    public override void detach(XmppStream stream) {
        stream.get_module(Message.Module.IDENTITY).received_message.disconnect(on_received_message);
        stream.get_module(Presence.Module.IDENTITY).received_presence.disconnect(on_received_presence);
        stream.get_module(Presence.Module.IDENTITY).received_available.disconnect(on_received_available);
        stream.get_module(Presence.Module.IDENTITY).received_unavailable.disconnect(on_received_unavailable);
    }

    public static void require(XmppStream stream) {
        Presence.Module.require(stream);
        if (stream.get_module(IDENTITY) == null) stream.add_module(new Muc.Module());
    }

    public override string get_ns() { return NS_URI; }
    public override string get_id() { return IDENTITY.id; }

    private void change_role(XmppStream stream, string jid, string nick, string new_role) {
        StanzaNode query = new StanzaNode.build("query", NS_URI_ADMIN).add_self_xmlns();
        query.put_node(new StanzaNode.build("item", NS_URI_ADMIN).put_attribute("nick", nick, NS_URI_ADMIN).put_attribute("role", new_role, NS_URI_ADMIN));
        Iq.Stanza iq = new Iq.Stanza.set(query);
        iq.to = jid;
        stream.get_module(Iq.Module.IDENTITY).send_iq(stream, iq);
    }

    private void on_received_message(XmppStream stream, Message.Stanza message) {
        if (message.type_ == Message.Stanza.TYPE_GROUPCHAT) {
            StanzaNode? subject_node = message.stanza.get_subnode("subject");
            if (subject_node != null) {
                string subject = subject_node.get_string_content();
                stream.get_flag(Flag.IDENTITY).set_muc_subject(message.from, subject);
                subject_set(stream, subject, message.from);
            }
        }
    }

    private void on_received_presence(XmppStream stream, Presence.Stanza presence) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        if (presence.is_error() && flag.is_muc_enter_outstanding() && flag.is_occupant(presence.from)) {
            string bare_jid = get_bare_jid(presence.from);
            ErrorStanza? error_stanza = presence.get_error();
            if (flag.get_enter_id(bare_jid) == error_stanza.original_id) {
                ListenerHolder listener = flag.get_enter_listener(bare_jid);
                MucEnterError? error = null;
                if (error_stanza.condition == ErrorStanza.CONDITION_NOT_AUTHORIZED && ErrorStanza.TYPE_AUTH == error_stanza.type_) {
                    error = MucEnterError.PASSWORD_REQUIRED;
                } else if (ErrorStanza.CONDITION_REGISTRATION_REQUIRED == error_stanza.condition && ErrorStanza.TYPE_AUTH == error_stanza.type_) {
                    error = MucEnterError.NOT_IN_MEMBER_LIST;
                } else if (ErrorStanza.CONDITION_FORBIDDEN == error_stanza.condition && ErrorStanza.TYPE_AUTH == error_stanza.type_) {
                    error = MucEnterError.BANNED;
                } else if (ErrorStanza.CONDITION_CONFLICT == error_stanza.condition && ErrorStanza.TYPE_CANCEL == error_stanza.type_) {
                    error = MucEnterError.NICK_CONFLICT;
                } else if (ErrorStanza.CONDITION_SERVICE_UNAVAILABLE == error_stanza.condition && ErrorStanza.TYPE_WAIT == error_stanza.type_) {
                    error = MucEnterError.OCCUPANT_LIMIT_REACHED;
                } else if (ErrorStanza.CONDITION_ITEM_NOT_FOUND == error_stanza.condition && ErrorStanza.TYPE_CANCEL == error_stanza.type_) {
                    error = MucEnterError.ROOM_DOESNT_EXIST;
                }
                if (error == null) listener.on_error(stream, error, listener.reference);
                flag.finish_muc_enter(bare_jid);
            }
        }
    }

    private void on_received_available(XmppStream stream, Presence.Stanza presence) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        if (flag.is_occupant(presence.from)) {
            StanzaNode? x_node = presence.stanza.get_subnode("x", NS_URI_USER);
            if (x_node != null) {
                ArrayList<int> status_codes = get_status_codes(x_node);
                if (status_codes.contains(StatusCode.SELF_PRESENCE)) {
                    string bare_jid = get_bare_jid(presence.from);
                    ListenerHolder listener = flag.get_enter_listener(bare_jid);
                    listener.on_success(stream, listener.reference);
                    flag.finish_muc_enter(bare_jid, get_resource_part(presence.from));
                }
                string? affiliation = x_node["item", "affiliation"].val;
                if (affiliation != null) {
                    received_occupant_affiliation(stream, presence.from, affiliation);
                }
                string? jid = x_node["item", "jid"].val;
                if (jid != null) {
                    flag.set_real_jid(presence.from, jid);
                    received_occupant_jid(stream, presence.from, jid);
                }
                string? role = x_node["item", "role"].val;
                if (role != null) {
                    received_occupant_role(stream, presence.from, role);
                }
            }
        }
    }

    private void on_received_unavailable(XmppStream stream, string jid) {
        Flag flag = stream.get_flag(Flag.IDENTITY);
        if (flag.is_occupant(jid)) {
            flag.remove_occupant_info(jid);
        }
    }

    private ArrayList<int> get_status_codes(StanzaNode x_node) {
        ArrayList<int> ret = new ArrayList<int>();
        foreach (StanzaNode status_node in x_node.get_subnodes("status", NS_URI_USER)) {
            ret.add(int.parse(status_node.get_attribute("code")));
        }
        return ret;
    }
}

public enum StatusCode {
    /** Inform user that any occupant is allowed to see the user's full JID */
    JID_VISIBLE = 100,
    /** Inform user that his or her affiliation changed while not in the room */
    AFFILIATION_CHANGED = 101,
    /** Inform occupants that room now shows unavailable members */
    SHOWS_UNAVIABLE_MEMBERS = 102,
    /** Inform occupants that room now does not show unavailable members */
    SHOWS_UNAVIABLE_MEMBERS_NOT = 103,
    /** Inform occupants that a non-privacy-related room configuration change has occurred */
    CONFIG_CHANGE_NON_PRIVACY = 104,
    /** Inform user that presence refers to itself */
    SELF_PRESENCE = 110,
    /** Inform occupants that room logging is now enabled */
    LOGGING_ENABLED = 170,
    /** Inform occupants that room logging is now disabled */
    LOGGING_DISABLED = 171,
    /** Inform occupants that the room is now non-anonymous */
    NON_ANONYMOUS = 172,
    /** Inform occupants that the room is now semi-anonymous */
    SEMI_ANONYMOUS = 173,
    /** Inform user that a new room has been created */
    NEW_ROOM_CREATED = 201,
    /** Inform user that service has assigned or modified occupant's roomnick */
    MODIFIED_NICK = 210,
    /** Inform user that he or she has been banned from the room */
    BANNED = 301,
    /** Inform all occupants of new room nickname */
    ROOM_NICKNAME = 303,
    /** Inform user that he or she has been kicked from the room */
    KICKED = 307,
    /** Inform user that he or she is being removed from the room */
    REMOVED_AFFILIATION_CHANGE = 321,
    /** Inform user that he or she is being removed from the room because the room has been changed to members-only
    and the user is not a member */
    REMOVED_MEMBERS_ONLY = 322,
    /** Inform user that he or she is being removed from the room because the MUC service is being shut down */
    REMOVED_SHUTDOWN = 332
}

public class ListenerHolder {
    [CCode (has_target = false)] public delegate void OnSuccess(XmppStream stream, Object? store);
    public OnSuccess on_success { get; private set; }
    [CCode (has_target = false)] public delegate void OnError(XmppStream stream, MucEnterError error, Object? store);
    public OnError on_error { get; private set; }
    public Object? reference { get; private set; }

    public ListenerHolder(OnSuccess on_success, OnError on_error, Object? reference = null) {
        this.on_success = on_success;
        this.reference = reference;
    }
}

}
