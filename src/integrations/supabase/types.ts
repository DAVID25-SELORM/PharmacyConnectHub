export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5";
  };
  public: {
    Tables: {
      businesses: {
        Row: {
          address: string | null;
          city: string | null;
          created_at: string;
          id: string;
          license_number: string | null;
          location_description: string | null;
          name: string;
          owner_id: string;
          owner_is_superintendent: boolean;
          phone: string | null;
          public_email: string | null;
          region: string | null;
          rejection_reason: string | null;
          superintendent_name: string | null;
          type: Database["public"]["Enums"]["business_type"];
          updated_at: string;
          verification_status: Database["public"]["Enums"]["verification_status"];
          verified_at: string | null;
          working_hours: string | null;
        };
        Insert: {
          address?: string | null;
          city?: string | null;
          created_at?: string;
          id?: string;
          license_number?: string | null;
          location_description?: string | null;
          name: string;
          owner_id: string;
          owner_is_superintendent?: boolean;
          phone?: string | null;
          public_email?: string | null;
          region?: string | null;
          rejection_reason?: string | null;
          superintendent_name?: string | null;
          type: Database["public"]["Enums"]["business_type"];
          updated_at?: string;
          verification_status?: Database["public"]["Enums"]["verification_status"];
          verified_at?: string | null;
          working_hours?: string | null;
        };
        Update: {
          address?: string | null;
          city?: string | null;
          created_at?: string;
          id?: string;
          license_number?: string | null;
          location_description?: string | null;
          name?: string;
          owner_id?: string;
          owner_is_superintendent?: boolean;
          phone?: string | null;
          public_email?: string | null;
          region?: string | null;
          rejection_reason?: string | null;
          superintendent_name?: string | null;
          type?: Database["public"]["Enums"]["business_type"];
          updated_at?: string;
          verification_status?: Database["public"]["Enums"]["verification_status"];
          verified_at?: string | null;
          working_hours?: string | null;
        };
        Relationships: [];
      };
      business_private_contacts: {
        Row: {
          business_id: string;
          created_at: string;
          owner_email: string | null;
          owner_full_name: string | null;
          owner_phone: string | null;
          superintendent_email: string | null;
          superintendent_full_name: string | null;
          superintendent_phone: string | null;
          updated_at: string;
        };
        Insert: {
          business_id: string;
          created_at?: string;
          owner_email?: string | null;
          owner_full_name?: string | null;
          owner_phone?: string | null;
          superintendent_email?: string | null;
          superintendent_full_name?: string | null;
          superintendent_phone?: string | null;
          updated_at?: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          owner_email?: string | null;
          owner_full_name?: string | null;
          owner_phone?: string | null;
          superintendent_email?: string | null;
          superintendent_full_name?: string | null;
          superintendent_phone?: string | null;
          updated_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "business_private_contacts_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: true;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      business_staff: {
        Row: {
          business_id: string;
          created_at: string;
          id: string;
          invited_at: string;
          invited_by: string | null;
          joined_at: string | null;
          role: Database["public"]["Enums"]["staff_role"];
          status: Database["public"]["Enums"]["staff_status"];
          updated_at: string;
          user_id: string;
        };
        Insert: {
          business_id: string;
          created_at?: string;
          id?: string;
          invited_at?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role?: Database["public"]["Enums"]["staff_role"];
          status?: Database["public"]["Enums"]["staff_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          business_id?: string;
          created_at?: string;
          id?: string;
          invited_at?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role?: Database["public"]["Enums"]["staff_role"];
          status?: Database["public"]["Enums"]["staff_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "business_staff_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      license_documents: {
        Row: {
          business_id: string;
          doc_type: string;
          id: string;
          storage_path: string;
          uploaded_at: string;
        };
        Insert: {
          business_id: string;
          doc_type: string;
          id?: string;
          storage_path: string;
          uploaded_at?: string;
        };
        Update: {
          business_id?: string;
          doc_type?: string;
          id?: string;
          storage_path?: string;
          uploaded_at?: string;
        };
        Relationships: [
          {
            foreignKeyName: "license_documents_business_id_fkey";
            columns: ["business_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      notifications: {
        Row: {
          body: string;
          created_at: string;
          id: string;
          metadata: Json | null;
          read: boolean;
          title: string;
          type: string;
          user_id: string;
        };
        Insert: {
          body: string;
          created_at?: string;
          id?: string;
          metadata?: Json | null;
          read?: boolean;
          title: string;
          type: string;
          user_id: string;
        };
        Update: {
          body?: string;
          created_at?: string;
          id?: string;
          metadata?: Json | null;
          read?: boolean;
          title?: string;
          type?: string;
          user_id?: string;
        };
        Relationships: [];
      };
      order_items: {
        Row: {
          id: string;
          order_id: string;
          product_id: string;
          product_name: string;
          quantity: number;
          unit_price_ghs: number;
        };
        Insert: {
          id?: string;
          order_id: string;
          product_id: string;
          product_name: string;
          quantity: number;
          unit_price_ghs: number;
        };
        Update: {
          id?: string;
          order_id?: string;
          product_id?: string;
          product_name?: string;
          quantity?: number;
          unit_price_ghs?: number;
        };
        Relationships: [
          {
            foreignKeyName: "order_items_order_id_fkey";
            columns: ["order_id"];
            isOneToOne: false;
            referencedRelation: "orders";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "order_items_product_id_fkey";
            columns: ["product_id"];
            isOneToOne: false;
            referencedRelation: "products";
            referencedColumns: ["id"];
          },
        ];
      };
      order_status_history: {
        Row: {
          changed_by: string | null;
          created_at: string;
          from_status: Database["public"]["Enums"]["order_status"] | null;
          id: string;
          note: string | null;
          order_id: string;
          to_status: Database["public"]["Enums"]["order_status"];
        };
        Insert: {
          changed_by?: string | null;
          created_at?: string;
          from_status?: Database["public"]["Enums"]["order_status"] | null;
          id?: string;
          note?: string | null;
          order_id: string;
          to_status: Database["public"]["Enums"]["order_status"];
        };
        Update: {
          changed_by?: string | null;
          created_at?: string;
          from_status?: Database["public"]["Enums"]["order_status"] | null;
          id?: string;
          note?: string | null;
          order_id?: string;
          to_status?: Database["public"]["Enums"]["order_status"];
        };
        Relationships: [
          {
            foreignKeyName: "order_status_history_order_id_fkey";
            columns: ["order_id"];
            isOneToOne: false;
            referencedRelation: "orders";
            referencedColumns: ["id"];
          },
        ];
      };
      orders: {
        Row: {
          accepted_at: string | null;
          cancellation_reason: string | null;
          cancelled_at: string | null;
          created_at: string;
          delivered_at: string | null;
          dispatched_at: string | null;
          id: string;
          notes: string | null;
          order_number: string;
          packed_at: string | null;
          paid_at: string | null;
          payment_confirmed_at: string | null;
          payment_confirmed_by: string | null;
          payment_method: Database["public"]["Enums"]["payment_method"];
          payment_status: Database["public"]["Enums"]["payment_status"];
          paystack_access_code: string | null;
          paystack_reference: string | null;
          pharmacy_id: string;
          receipt_sent_at: string | null;
          receipt_sent_to: string | null;
          status: Database["public"]["Enums"]["order_status"];
          total_ghs: number;
          updated_at: string;
          wholesaler_id: string;
        };
        Insert: {
          accepted_at?: string | null;
          cancellation_reason?: string | null;
          cancelled_at?: string | null;
          created_at?: string;
          delivered_at?: string | null;
          dispatched_at?: string | null;
          id?: string;
          notes?: string | null;
          order_number?: string;
          packed_at?: string | null;
          paid_at?: string | null;
          payment_confirmed_at?: string | null;
          payment_confirmed_by?: string | null;
          payment_method?: Database["public"]["Enums"]["payment_method"];
          payment_status?: Database["public"]["Enums"]["payment_status"];
          paystack_access_code?: string | null;
          paystack_reference?: string | null;
          pharmacy_id: string;
          receipt_sent_at?: string | null;
          receipt_sent_to?: string | null;
          status?: Database["public"]["Enums"]["order_status"];
          total_ghs?: number;
          updated_at?: string;
          wholesaler_id: string;
        };
        Update: {
          accepted_at?: string | null;
          cancellation_reason?: string | null;
          cancelled_at?: string | null;
          created_at?: string;
          delivered_at?: string | null;
          dispatched_at?: string | null;
          id?: string;
          notes?: string | null;
          order_number?: string;
          packed_at?: string | null;
          paid_at?: string | null;
          payment_confirmed_at?: string | null;
          payment_confirmed_by?: string | null;
          payment_method?: Database["public"]["Enums"]["payment_method"];
          payment_status?: Database["public"]["Enums"]["payment_status"];
          paystack_access_code?: string | null;
          paystack_reference?: string | null;
          pharmacy_id?: string;
          receipt_sent_at?: string | null;
          receipt_sent_to?: string | null;
          status?: Database["public"]["Enums"]["order_status"];
          total_ghs?: number;
          updated_at?: string;
          wholesaler_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "orders_pharmacy_id_fkey";
            columns: ["pharmacy_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
          {
            foreignKeyName: "orders_wholesaler_id_fkey";
            columns: ["wholesaler_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      platform_staff: {
        Row: {
          created_at: string;
          id: string;
          invited_at: string;
          invited_by: string | null;
          joined_at: string | null;
          role: Database["public"]["Enums"]["platform_staff_role"];
          status: Database["public"]["Enums"]["staff_status"];
          updated_at: string;
          user_id: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          invited_at?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role?: Database["public"]["Enums"]["platform_staff_role"];
          status?: Database["public"]["Enums"]["staff_status"];
          updated_at?: string;
          user_id: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          invited_at?: string;
          invited_by?: string | null;
          joined_at?: string | null;
          role?: Database["public"]["Enums"]["platform_staff_role"];
          status?: Database["public"]["Enums"]["staff_status"];
          updated_at?: string;
          user_id?: string;
        };
        Relationships: [];
      };
      products: {
        Row: {
          active: boolean;
          brand: string | null;
          category: string | null;
          created_at: string;
          form: string | null;
          id: string;
          image_hue: number | null;
          name: string;
          pack_size: string | null;
          price_ghs: number;
          stock: number;
          updated_at: string;
          wholesaler_id: string;
        };
        Insert: {
          active?: boolean;
          brand?: string | null;
          category?: string | null;
          created_at?: string;
          form?: string | null;
          id?: string;
          image_hue?: number | null;
          name: string;
          pack_size?: string | null;
          price_ghs: number;
          stock?: number;
          updated_at?: string;
          wholesaler_id: string;
        };
        Update: {
          active?: boolean;
          brand?: string | null;
          category?: string | null;
          created_at?: string;
          form?: string | null;
          id?: string;
          image_hue?: number | null;
          name?: string;
          pack_size?: string | null;
          price_ghs?: number;
          stock?: number;
          updated_at?: string;
          wholesaler_id?: string;
        };
        Relationships: [
          {
            foreignKeyName: "products_wholesaler_id_fkey";
            columns: ["wholesaler_id"];
            isOneToOne: false;
            referencedRelation: "businesses";
            referencedColumns: ["id"];
          },
        ];
      };
      profiles: {
        Row: {
          created_at: string;
          full_name: string | null;
          id: string;
          phone: string | null;
          updated_at: string;
        };
        Insert: {
          created_at?: string;
          full_name?: string | null;
          id: string;
          phone?: string | null;
          updated_at?: string;
        };
        Update: {
          created_at?: string;
          full_name?: string | null;
          id?: string;
          phone?: string | null;
          updated_at?: string;
        };
        Relationships: [];
      };
      user_roles: {
        Row: {
          created_at: string;
          id: string;
          role: Database["public"]["Enums"]["app_role"];
          user_id: string;
        };
        Insert: {
          created_at?: string;
          id?: string;
          role: Database["public"]["Enums"]["app_role"];
          user_id: string;
        };
        Update: {
          created_at?: string;
          id?: string;
          role?: Database["public"]["Enums"]["app_role"];
          user_id?: string;
        };
        Relationships: [];
      };
    };
    Views: {
      [_ in never]: never;
    };
    Functions: {
      add_business_staff_by_email: {
        Args: {
          _business_id: string;
          _email: string;
          _role: Database["public"]["Enums"]["staff_role"];
        };
        Returns: Database["public"]["Tables"]["business_staff"]["Row"];
      };
      update_business_profile_with_contacts: {
        Args: {
          _address: string | null;
          _business_id: string;
          _city: string | null;
          _license_number: string | null;
          _location_description: string | null;
          _name: string;
          _owner_email: string;
          _owner_full_name: string;
          _owner_is_superintendent: boolean | null;
          _owner_phone: string;
          _phone: string | null;
          _public_email: string | null;
          _region: string | null;
          _superintendent_email: string | null;
          _superintendent_name: string | null;
          _superintendent_phone: string | null;
          _working_hours: string | null;
        };
        Returns: {
          business_id: string;
          owner_email: string | null;
          owner_full_name: string | null;
          owner_phone: string | null;
          superintendent_email: string | null;
          superintendent_full_name: string | null;
          superintendent_phone: string | null;
        }[];
      };
      get_user_business_context: {
        Args: Record<PropertyKey, never>;
        Returns: {
          address: string | null;
          city: string | null;
          id: string;
          license_number: string | null;
          location_description: string | null;
          name: string;
          owner_is_superintendent: boolean;
          phone: string | null;
          public_email: string | null;
          region: string | null;
          rejection_reason: string | null;
          staff_role: Database["public"]["Enums"]["staff_role"];
          superintendent_name: string | null;
          type: Database["public"]["Enums"]["business_type"];
          verification_status: Database["public"]["Enums"]["verification_status"];
          working_hours: string | null;
        }[];
      };
      has_role: {
        Args: {
          _user_id: string;
          _role: Database["public"]["Enums"]["app_role"];
        };
        Returns: boolean;
      };
      is_platform_owner: {
        Args: {
          _user_id: string;
        };
        Returns: boolean;
      };
      is_platform_staff: {
        Args: {
          _user_id: string;
        };
        Returns: boolean;
      };
      is_business_staff: {
        Args: {
          _business_id: string;
          _user_id: string;
        };
        Returns: boolean;
      };
      get_staff_role: {
        Args: {
          _business_id: string;
          _user_id: string;
        };
        Returns: Database["public"]["Enums"]["staff_role"];
      };
      list_business_staff: {
        Args: {
          _business_id: string;
        };
        Returns: {
          full_name: string | null;
          id: string;
          invited_at: string;
          joined_at: string | null;
          phone: string | null;
          role: Database["public"]["Enums"]["staff_role"];
          status: Database["public"]["Enums"]["staff_status"];
          user_email: string | null;
          user_id: string;
        }[];
      };
      list_platform_staff: {
        Args: Record<PropertyKey, never>;
        Returns: {
          full_name: string | null;
          id: string;
          invited_at: string;
          joined_at: string | null;
          phone: string | null;
          role: Database["public"]["Enums"]["platform_staff_role"];
          status: Database["public"]["Enums"]["staff_status"];
          user_email: string | null;
          user_id: string;
        }[];
      };
    };
    Enums: {
      app_role: "admin" | "pharmacy" | "wholesaler";
      business_type: "pharmacy" | "wholesaler";
      order_status: "pending" | "accepted" | "packed" | "dispatched" | "delivered" | "cancelled";
      payment_method: "cod" | "paystack";
      payment_status: "unpaid" | "paid" | "refunded" | "failed";
      platform_staff_role: "owner" | "admin";
      staff_role: "owner" | "manager" | "cashier" | "assistant";
      staff_status: "active" | "inactive" | "pending";
      verification_status: "pending" | "approved" | "rejected";
    };
    CompositeTypes: {
      [_ in never]: never;
    };
  };
};

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">;

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">];

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R;
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] & DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R;
      }
      ? R
      : never
    : never;

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I;
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I;
      }
      ? I
      : never
    : never;

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U;
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U;
      }
      ? U
      : never
    : never;

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never;

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals;
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals;
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never;

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "pharmacy", "wholesaler"],
      business_type: ["pharmacy", "wholesaler"],
      order_status: ["pending", "accepted", "packed", "dispatched", "delivered", "cancelled"],
      payment_method: ["cod", "paystack"],
      payment_status: ["unpaid", "paid", "refunded", "failed"],
      platform_staff_role: ["owner", "admin"],
      staff_role: ["owner", "manager", "cashier", "assistant"],
      staff_status: ["active", "inactive", "pending"],
      verification_status: ["pending", "approved", "rejected"],
    },
  },
} as const;
